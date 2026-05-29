defmodule Cympho.DataIntegrityPr4Test do
  @moduledoc """
  PR 4 (REQ-004): single-query assignment counts, company-scoped approval
  listing, and safe (whitelist) interaction-status parsing.
  """
  use CymphoWeb.ConnCase, async: true

  alias Cympho.{Agents, Approvals, Companies, Issues}

  defp company(name) do
    {:ok, c} =
      Companies.create_company(%{
        name: name,
        slug: "#{name}-#{System.unique_integer([:positive])}"
      })

    c
  end

  describe "Agents.count_active_assignments_by_company/1 (AC-019)" do
    test "returns per-agent :in_progress counts in a single map" do
      c = company("perf")
      {:ok, a1} = Agents.create_agent(%{name: "a1", role: :engineer, company_id: c.id})
      {:ok, a2} = Agents.create_agent(%{name: "a2", role: :engineer, company_id: c.id})

      for _ <- 1..2,
          do:
            Issues.create_issue(%{
              title: "x",
              company_id: c.id,
              status: :in_progress,
              assignee_id: a1.id
            })

      {:ok, _} =
        Issues.create_issue(%{
          title: "y",
          company_id: c.id,
          status: :in_progress,
          assignee_id: a2.id
        })

      # A non-:in_progress issue must not be counted.
      {:ok, _} =
        Issues.create_issue(%{title: "z", company_id: c.id, status: :todo, assignee_id: a2.id})

      map = Agents.count_active_assignments_by_company(c.id)

      assert map[a1.id] == 2
      assert map[a2.id] == 1
    end
  end

  describe "Approvals.list_approvals/1 company scoping (AC-020)" do
    test "filters by company in the query, excluding other tenants" do
      ca = company("appr-a")
      cb = company("appr-b")
      {:ok, agent_a} = Agents.create_agent(%{name: "aa", role: :engineer, company_id: ca.id})
      {:ok, agent_b} = Agents.create_agent(%{name: "ab", role: :engineer, company_id: cb.id})

      {:ok, _} =
        Approvals.create_approval(%{
          type: "request_board_approval",
          requested_by_agent_id: agent_a.id
        })

      {:ok, _} =
        Approvals.create_approval(%{
          type: "request_board_approval",
          requested_by_agent_id: agent_b.id
        })

      a_list = Approvals.list_approvals(%{company_id: ca.id})

      assert length(a_list) == 1
      assert Enum.all?(a_list, fn ap -> ap.requested_by.company_id == ca.id end)
    end
  end

  describe "IssueInteractionController.resolve invalid status (AC-022)" do
    test "rejects an unknown status with :invalid_status instead of raising" do
      c = company("intr")

      {:ok, user} =
        Cympho.Authentication.register_user(%{
          email: "pr4-#{System.unique_integer([:positive])}@example.com",
          name: "U",
          password: "password1234"
        })

      {:ok, issue} = Issues.create_issue(%{title: "i", company_id: c.id, status: :todo})

      conn =
        build_conn()
        |> Plug.Conn.assign(:current_user, user)
        |> Plug.Conn.assign(:current_company, c)

      result =
        CymphoWeb.IssueInteractionController.resolve(conn, %{
          "issue_id" => issue.id,
          "id" => Ecto.UUID.generate(),
          "status" => "definitely-not-valid"
        })

      assert {:error, :invalid_status} = result
    end
  end
end
