defmodule CymphoWeb.IssueExecutionPolicyControllerTest do
  use CymphoWeb.ConnCase, async: false

  alias Cympho.Issues
  alias Cympho.ExecutionPolicies
  alias Cympho.Agents

  setup %{conn: conn} do
    {conn, _user, company} = register_and_log_in_user(conn)
    %{conn: conn, company: company}
  end

  describe "POST /api/issues/:issue_id/execution-policy/assign" do
    test "assigns execution policy to issue", %{conn: conn, company: company} do
      {:ok, executor} =
        Agents.create_agent(%{name: "Executor", role: :engineer, company_id: company.id})

      {:ok, policy} =
        ExecutionPolicies.create_execution_policy(%{
          "name" => "Test Assign Policy",
          "stage_configs" => [
            %{"type" => "executor", "participant_id" => executor.id},
            %{"type" => "approver", "participant_id" => "someone"}
          ]
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "API Assign Test",
          description: "Test",
          company_id: company.id
        })

      conn =
        post(conn, "/api/issues/#{issue.id}/execution-policy/assign", %{
          "execution_policy_id" => policy.id,
          "executor_id" => executor.id
        })

      assert json_response(conn, 200)
      body = json_response(conn, 200)
      assert body["execution_policy_id"] == policy.id
      assert body["execution_state"]["current_stage_type"] == "executor"
    end

    test "returns error for non-existent issue", %{conn: conn} do
      conn =
        post(conn, "/api/issues/#{Ecto.UUID.generate()}/execution-policy/assign", %{
          "execution_policy_id" => Ecto.UUID.generate(),
          "executor_id" => "nonexistent"
        })

      assert conn.status == 404
    end
  end

  describe "POST /api/issues/:issue_id/execution-policy/decide" do
    test "approves at current stage", %{conn: conn, company: company} do
      {:ok, executor} =
        Agents.create_agent(%{name: "Exec", role: :engineer, company_id: company.id})

      {:ok, approver} =
        Agents.create_agent(%{name: "Approver", role: :ceo, company_id: company.id})

      {:ok, policy} =
        ExecutionPolicies.create_execution_policy(%{
          "name" => "Decide Test",
          "stage_configs" => [
            %{"type" => "executor", "participant_id" => executor.id},
            %{"type" => "approver", "participant_id" => approver.id}
          ]
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "API Decide Test",
          description: "Test",
          company_id: company.id
        })

      {:ok, assigned} = Issues.assign_execution_policy(issue, policy.id, executor.id)
      {:ok, _at_approver} = Issues.transition_issue(assigned, :in_review, executor.id)

      conn =
        post(conn, "/api/issues/#{issue.id}/execution-policy/decide", %{
          "decision" => "approve",
          "decided_by" => approver.id
        })

      assert json_response(conn, 200)
      body = json_response(conn, 200)
      assert body["status"] == "done"
    end

    test "requests changes at current stage", %{conn: conn, company: company} do
      {:ok, executor} =
        Agents.create_agent(%{name: "Exec", role: :engineer, company_id: company.id})

      {:ok, reviewer} = Agents.create_agent(%{name: "Rev", role: :cto, company_id: company.id})

      {:ok, policy} =
        ExecutionPolicies.create_execution_policy(%{
          "name" => "Changes Test",
          "stage_configs" => [
            %{"type" => "executor", "participant_id" => executor.id},
            %{"type" => "reviewer", "participant_id" => reviewer.id}
          ]
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "API Changes Test",
          description: "Test",
          company_id: company.id
        })

      {:ok, assigned} = Issues.assign_execution_policy(issue, policy.id, executor.id)
      {:ok, _at_reviewer} = Issues.transition_issue(assigned, :in_review, executor.id)

      conn =
        post(conn, "/api/issues/#{issue.id}/execution-policy/decide", %{
          "decision" => "request_changes",
          "decided_by" => reviewer.id
        })

      assert json_response(conn, 200)
      body = json_response(conn, 200)
      assert body["status"] == "in_progress"
    end
  end
end
