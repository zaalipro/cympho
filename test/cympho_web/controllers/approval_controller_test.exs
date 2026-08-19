defmodule CymphoWeb.ApprovalControllerTest do
  use CymphoWeb.ConnCase, async: true

  import Ecto.Query

  alias Cympho.{Agents, Approvals, Repo}
  alias Cympho.Decisions.Decision

  test "ordinary company members cannot resolve approvals through the API", %{conn: conn} do
    {conn, user, company} = register_and_log_in_user(conn, %{role: "member"})
    approval = create_approval(company)

    conn =
      patch(conn, ~p"/api/approvals/#{approval.id}", %{
        "approval" => %{"status" => "approved"}
      })

    assert json_response(conn, 403)
    assert Approvals.get_approval!(approval.id).status == :pending
    refute Repo.exists?(from d in Decision, where: d.resource_id == ^approval.id)
    refute Approvals.resolver_authorized?(user.id, company.id)
  end

  test "an authorized resolver atomically records the approval Decision", %{conn: conn} do
    {conn, user, company} = register_and_log_in_user(conn, %{role: "owner"})
    approval = create_approval(company)

    conn =
      patch(conn, ~p"/api/approvals/#{approval.id}", %{
        "approval" => %{
          "status" => "approved",
          "resolution_reason" => "Owner approved the release"
        }
      })

    assert %{
             "data" => %{
               "id" => id,
               "status" => "approved",
               "resolved_by_user_id" => resolver_id
             }
           } = json_response(conn, 200)

    assert id == approval.id
    assert resolver_id == user.id

    decision = Repo.one!(from d in Decision, where: d.resource_id == ^approval.id)
    assert decision.company_id == company.id
    assert decision.actor_id == user.id
    assert decision.outcome == "approved"
  end

  test "a member board resolver reaches the target authorization", %{conn: conn} do
    {conn, user, company} =
      register_and_log_in_user(conn, %{role: "member", is_board_member: true})

    approval = create_approval(company)

    conn =
      patch(conn, ~p"/api/approvals/#{approval.id}", %{
        "approval" => %{"status" => "approved", "resolution_reason" => "Board approved"}
      })

    assert %{"data" => %{"status" => "approved", "resolved_by_user_id" => resolver_id}} =
             json_response(conn, 200)

    assert resolver_id == user.id
  end

  test "a viewer remains read-only even with a board flag", %{conn: conn} do
    {conn, _user, company} =
      register_and_log_in_user(conn, %{role: "viewer", is_board_member: true})

    approval = create_approval(company)

    conn =
      patch(conn, ~p"/api/approvals/#{approval.id}", %{
        "approval" => %{"status" => "approved"}
      })

    assert json_response(conn, 403)
    assert Approvals.get_approval!(approval.id).status == :pending
  end

  defp create_approval(company) do
    unique = System.unique_integer([:positive])

    {:ok, agent} =
      Agents.create_agent(%{
        name: "API Approval Agent #{unique}",
        role: :engineer,
        company_id: company.id,
        url_key: "api-approval-agent-#{unique}"
      })

    {:ok, approval} =
      Approvals.create_approval(%{
        type: "release_gate",
        requested_by_agent_id: agent.id
      })

    approval
  end
end
