defmodule Cympho.CompanyPauseResumeTest do
  use Cympho.DataCase

  alias Cympho.Companies
  alias Cympho.Agents
  alias Cympho.Agents.Agent
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.Issues
  alias Cympho.Issues.Issue
  alias Cympho.Orchestrator.Dispatcher
  alias Cympho.Wakes
  alias Cympho.Wakes.AgentWake

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
        assert reloaded.status == :paused
      end
    end

    test "preserves queued wakes for resume", %{company: company} do
      agent = Agents.list_agents_by_company(company.id) |> hd()

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Queued wake survives pause",
          company_id: company.id,
          status: :todo,
          assignee_id: agent.id
        })

      {:ok, wake} =
        Wakes.do_wake_agent(agent.id, issue.id, "manual_dispatch", "system", nil, %{
          "source" => "test"
        })

      {:ok, _} = Companies.pause_company(company, "operator pause")

      assert Repo.get!(AgentWake, wake.id).status == "pending"
    end

    test "pause runtime releases active work but preserves queued wakes", %{company: company} do
      agent = Agents.list_agents_by_company(company.id) |> hd()
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, active_issue} =
        Issues.create_issue(%{
          title: "Active wake-safe pause",
          company_id: company.id,
          status: :in_progress,
          assignee_id: agent.id,
          checked_out_at: now,
          started_at: now
        })

      run =
        Repo.insert!(%Run{
          company_id: company.id,
          agent_id: agent.id,
          issue_id: active_issue.id,
          status: "running",
          adapter: "process",
          started_at: now,
          last_heartbeat_at: now
        })

      {:ok, queued_issue} =
        Issues.create_issue(%{
          title: "Queued wake survives runtime pause",
          company_id: company.id,
          status: :todo,
          assignee_id: agent.id
        })

      {:ok, wake} =
        Wakes.do_wake_agent(agent.id, queued_issue.id, "manual_dispatch", "system", nil, %{
          "source" => "runtime-pause"
        })

      assert {:ok, _updated, runtime_stop} =
               Companies.pause_company_runtime(company, "operator pause")

      assert runtime_stop.issues_released == 1
      assert runtime_stop.runs_cancelled == 1
      assert runtime_stop.wakes_cancelled == 0

      reloaded_issue = Repo.get!(Issue, active_issue.id)
      assert reloaded_issue.status == :todo
      assert reloaded_issue.assignee_id == nil
      assert Repo.get!(Run, run.id).status == "cancelled"
      assert Repo.get!(AgentWake, wake.id).status == "pending"
    end

    test "pending wakes cannot dispatch while company is paused", %{company: company} do
      agent = Agents.list_agents_by_company(company.id) |> hd()

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Paused company queued wake",
          company_id: company.id,
          status: :todo,
          assignee_id: agent.id
        })

      {:ok, wake} =
        Wakes.do_wake_agent(agent.id, issue.id, "manual_dispatch", "system", nil, %{
          "source" => "pause-regression"
        })

      {:ok, _paused} = Companies.pause_company(company, "operator pause")
      reloaded_issue = Repo.get!(Issue, issue.id)

      assert Repo.get!(AgentWake, wake.id).status == "pending"
      assert {:error, :no_agent_available} = Dispatcher.preview_agent_for_issue(reloaded_issue)
      refute Enum.any?(Agents.list_eligible_agents(:engineer, company.id), &(&1.id == agent.id))
      assert reloaded_issue.status == :todo

      {:ok, _resumed} = Companies.resume_company(Companies.get_company!(company.id))
      agent_id = agent.id
      assert {:ok, %{id: ^agent_id}} = Dispatcher.preview_agent_for_issue(reloaded_issue)
    end

    test "new focused wakes are rejected while company runtime is paused", %{company: company} do
      agent = Agents.list_agents_by_company(company.id) |> hd()

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Focused wake blocked by company pause",
          company_id: company.id,
          status: :todo,
          assignee_id: agent.id
        })

      {:ok, _paused, _runtime_stop} = Companies.pause_company_runtime(company, "operator pause")

      assert {:error, :company_paused} =
               Dispatcher.enqueue_wake(issue.id, "manual_dispatch", %{"source" => "operator"})

      assert [] = Wakes.list_issue_wakes(issue.id)
    end

    test "direct checkout is rejected while company runtime is paused", %{company: company} do
      agent = Agents.list_agents_by_company(company.id) |> hd()

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Checkout blocked by company pause",
          company_id: company.id,
          status: :todo
        })

      {:ok, _paused} = Companies.pause_company(company, "operator pause")

      assert {:error, :company_paused} = Issues.checkout_issue(issue, agent.id, :engineer)

      reloaded_issue = Repo.get!(Issue, issue.id)
      assert reloaded_issue.status == :todo
      assert is_nil(reloaded_issue.assignee_id)
      assert is_nil(reloaded_issue.checked_out_at)
    end

    test "resume only reactivates agents paused by the company runtime control", %{
      company: company
    } do
      [active_agent, manually_paused_agent | _] = Agents.list_agents_by_company(company.id)

      {:ok, manually_paused_agent} =
        Agents.pause_agent(manually_paused_agent, "Manual investigation")

      assert {:ok, _paused} = Companies.pause_company(company, "Operator hold")

      globally_paused = Repo.get!(Agent, active_agent.id)
      assert globally_paused.status == :paused
      assert globally_paused.governance_status == "paused"

      assert globally_paused.runtime_config["company_runtime_pause"]["source"] ==
               "global_runtime_control"

      still_manual = Repo.get!(Agent, manually_paused_agent.id)
      assert still_manual.status == :paused
      assert still_manual.governance_status == "paused"
      assert still_manual.pause_reason == "Manual investigation"
      refute Map.has_key?(still_manual.runtime_config || %{}, "company_runtime_pause")

      {:ok, _resumed} = Companies.resume_company(Companies.get_company!(company.id))

      resumed_active = Repo.get!(Agent, active_agent.id)
      assert resumed_active.status == :idle
      assert resumed_active.governance_status == "active"
      refute Map.has_key?(resumed_active.runtime_config || %{}, "company_runtime_pause")

      reloaded_manual = Repo.get!(Agent, manually_paused_agent.id)
      assert reloaded_manual.status == :paused
      assert reloaded_manual.governance_status == "paused"
      assert reloaded_manual.pause_reason == "Manual investigation"
    end

    test "releases active issue ownership and cancels active run", %{company: company} do
      agent = Agents.list_agents_by_company(company.id) |> hd()
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Stuck runtime issue",
          company_id: company.id,
          status: :in_progress,
          assignee_id: agent.id,
          checked_out_at: now,
          started_at: now
        })

      run =
        Repo.insert!(%Run{
          company_id: company.id,
          agent_id: agent.id,
          issue_id: issue.id,
          status: "running",
          adapter: "process",
          started_at: now,
          last_heartbeat_at: now
        })

      assert {:ok, _updated, runtime_stop} =
               Companies.stop_company_runtime(company, "operator stop")

      assert runtime_stop.issues_released == 1
      assert runtime_stop.runs_cancelled == 1

      reloaded_issue = Repo.get!(Issue, issue.id)
      assert reloaded_issue.status == :todo
      assert reloaded_issue.assignee_id == nil
      assert reloaded_issue.checked_out_at == nil

      assert Repo.get!(Run, run.id).status == "cancelled"

      reloaded_agent = Repo.get!(Agent, agent.id)
      assert reloaded_agent.status == :paused
      assert reloaded_agent.governance_status == "paused"
    end

    test "stop cancels queued wakes so no stopped work restarts later", %{company: company} do
      agent = Agents.list_agents_by_company(company.id) |> hd()

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Queued wake cancelled by stop",
          company_id: company.id,
          status: :todo,
          assignee_id: agent.id
        })

      {:ok, wake} =
        Wakes.do_wake_agent(agent.id, issue.id, "manual_dispatch", "system", nil, %{
          "source" => "test"
        })

      assert {:ok, _updated, runtime_stop} =
               Companies.stop_company_runtime(company, "operator stop")

      assert runtime_stop.wakes_cancelled == 1

      reloaded_wake = Repo.get!(AgentWake, wake.id)
      assert reloaded_wake.status == "cancelled"
      assert reloaded_wake.last_error == "operator stop"
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

  describe "low-power runtime mode" do
    setup [:create_company_with_agents]

    test "keeps the company active while marking low-power mode", %{company: company} do
      {:ok, updated} = Companies.enter_low_power_mode(company, "after hours")

      assert updated.status == "active"
      assert Companies.active?(updated)
      assert Companies.low_power?(updated)
      assert Companies.runtime_mode(updated) == :low_power
      assert updated.governance_config["runtime_mode"] == "low_power"
      assert updated.governance_config["runtime_mode_reason"] == "after hours"
      assert updated.governance_config["runtime_mode_started_at"]
    end

    test "automatic dispatcher candidates are limited to high and critical work", %{
      company: company
    } do
      {:ok, low_power_company} = Companies.enter_low_power_mode(company, "overnight")

      refute Dispatcher.runnable_candidate?(%Issue{
               status: :todo,
               priority: :medium,
               company_id: low_power_company.id,
               company: low_power_company,
               blocked_by: []
             })

      assert Dispatcher.runnable_candidate?(%Issue{
               status: :todo,
               priority: :high,
               company_id: low_power_company.id,
               company: low_power_company,
               blocked_by: []
             })

      assert Dispatcher.runnable_candidate?(%Issue{
               status: :todo,
               priority: :critical,
               company_id: low_power_company.id,
               company: low_power_company,
               blocked_by: []
             })
    end

    test "resume clears low-power mode", %{company: company} do
      {:ok, low_power_company} = Companies.enter_low_power_mode(company, "after hours")
      assert Companies.low_power?(low_power_company)

      {:ok, updated} = Companies.resume_company(low_power_company)

      refute Companies.low_power?(updated)
      assert Companies.runtime_mode(updated) == :standard
      refute Map.has_key?(updated.governance_config, "runtime_mode")
      refute Map.has_key?(updated.governance_config, "runtime_mode_reason")
      refute Map.has_key?(updated.governance_config, "runtime_mode_started_at")
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
        assert reloaded.status == :idle
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
