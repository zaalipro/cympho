defmodule Cympho.CompanyPauseResumeTest do
  use Cympho.DataCase

  alias Cympho.Companies
  alias Cympho.Agents
  alias Cympho.Agents.Agent

  defp create_company_with_agents(_context) do
    {:ok, company} =
      Companies.create_company(%{
        name: "Test Corp " <> Ecto.UUID.generate(),
        slug: "test-" <> Ecto.UUID.generate()
      })

    {:ok, _a1} =
      Agents.create_agent(%{name: "Engineer 1", role: :engineer, company_id: company.id})

    {:ok, _a2} =
      Agents.create_agent(%{name: "Engineer 2", role: :engineer, company_id: company.id})

    {:ok, company: company}
  end

  describe "pause_company/2" do
    setup [:create_company_with_agents]

    test "sets status to paused, records paused_at and paused_reason", %{company: company} do
      {:ok, updated} = Companies.pause_company(company, "budget exceeded")

      assert updated.status == "paused"
      assert updated.paused_at != nil
      assert updated.paused_reason == "budget exceeded"
    end

    test "pauses all active agents in the company", %{company: company} do
      {:ok, _} = Companies.pause_company(company, "manual pause")

      for agent <- Agents.list_agents_by_company(company.id) do
        reloaded = Repo.get!(Agent, agent.id)
        assert reloaded.governance_status == "paused"
      end
    end

    test "broadcasts company_paused event", %{company: company} do
      Phoenix.PubSub.subscribe(Cympho.PubSub, "company:#{company.id}:company")
      {:ok, _} = Companies.pause_company(company, "test")
      assert_received {:company_paused, _updated}
    end

    test "active?/1 returns false for paused company", %{company: company} do
      {:ok, updated} = Companies.pause_company(company, "test")
      refute Companies.active?(updated)
    end
  end

  describe "resume_company/1" do
    setup [:create_company_with_agents]

    test "sets status to active, clears paused_at and paused_reason", %{company: company} do
      {:ok, _} = Companies.pause_company(company, "setup pause")
      {:ok, updated} = Companies.resume_company(Companies.get_company!(company.id))

      assert updated.status == "active"
      assert updated.paused_at == nil
      assert updated.paused_reason == nil
    end

    test "resumes all paused agents", %{company: company} do
      {:ok, _} = Companies.pause_company(company, "setup pause")
      {:ok, _} = Companies.resume_company(Companies.get_company!(company.id))

      for agent <- Agents.list_agents_by_company(company.id) do
        reloaded = Repo.get!(Agent, agent.id)
        assert reloaded.governance_status == "active"
      end
    end

    test "broadcasts company_resumed event", %{company: company} do
      {:ok, _} = Companies.pause_company(company, "setup pause")

      Phoenix.PubSub.subscribe(Cympho.PubSub, "company:#{company.id}:company")
      {:ok, _} = Companies.resume_company(Companies.get_company!(company.id))
      assert_received {:company_resumed, _updated}
    end

    test "active?/1 returns true for resumed company", %{company: company} do
      {:ok, _} = Companies.pause_company(company, "setup pause")
      {:ok, updated} = Companies.resume_company(Companies.get_company!(company.id))
      assert Companies.active?(updated)
    end
  end

  describe "dispatcher skips paused companies" do
    test "active?/1 guards preflight checks" do
      {:ok, active} = Companies.create_company(%{name: "Active Corp", slug: "active-corp-a"})
      assert Companies.active?(active)

      {:ok, paused} = Companies.create_company(%{name: "Paused Corp", slug: "paused-corp-a"})
      {:ok, paused} = Companies.pause_company(paused, "test")
      refute Companies.active?(paused)
    end
  end
end
