defmodule CymphoWeb.IssueExecutionPolicyControllerTest do
  use CymphoWeb.ConnCase, async: false

  alias Cympho.Issues
  alias Cympho.ExecutionPolicies
  alias Cympho.Agents

  setup %{conn: conn} do
    {conn, user, company} = register_and_log_in_user(conn)
    %{conn: conn, user: user, company: company}
  end

  describe "POST /api/issues/:issue_id/execution-policy/assign" do
    test "assigns execution policy to issue", %{conn: conn, company: company} do
      {:ok, executor} =
        Agents.create_agent(%{name: "Executor", role: :engineer, company_id: company.id})

      {:ok, policy} =
        ExecutionPolicies.create_execution_policy(%{
          "name" => "Test Assign Policy",
          "company_id" => company.id,
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
    test "approves at current stage", %{conn: conn, company: company, user: user} do
      {:ok, executor} =
        Agents.create_agent(%{name: "Exec", role: :engineer, company_id: company.id})

      {:ok, policy} =
        ExecutionPolicies.create_execution_policy(%{
          "name" => "Decide Test",
          "company_id" => company.id,
          "stage_configs" => [
            %{"type" => "executor", "participant_id" => executor.id},
            %{"type" => "approver", "participant_id" => user.id}
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
          "decision" => "approve"
        })

      assert json_response(conn, 200)
      body = json_response(conn, 200)
      assert body["status"] == "done"
    end

    test "requests changes at current stage", %{conn: conn, company: company, user: user} do
      {:ok, executor} =
        Agents.create_agent(%{name: "Exec", role: :engineer, company_id: company.id})

      {:ok, policy} =
        ExecutionPolicies.create_execution_policy(%{
          "name" => "Changes Test",
          "company_id" => company.id,
          "stage_configs" => [
            %{"type" => "executor", "participant_id" => executor.id},
            %{"type" => "reviewer", "participant_id" => user.id}
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
          "decision" => "request_changes"
        })

      assert json_response(conn, 200)
      body = json_response(conn, 200)
      assert body["status"] == "in_progress"
    end

    test "ignores forged decided_by and uses current_user", %{
      conn: conn,
      company: company,
      user: user
    } do
      {:ok, executor} =
        Agents.create_agent(%{name: "Exec", role: :engineer, company_id: company.id})

      {:ok, policy} =
        ExecutionPolicies.create_execution_policy(%{
          "name" => "Forged Decide Test",
          "company_id" => company.id,
          "stage_configs" => [
            %{"type" => "executor", "participant_id" => executor.id},
            %{"type" => "approver", "participant_id" => user.id}
          ]
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Forged Decide Test",
          description: "Test",
          company_id: company.id
        })

      {:ok, assigned} = Issues.assign_execution_policy(issue, policy.id, executor.id)
      {:ok, _at_approver} = Issues.transition_issue(assigned, :in_review, executor.id)

      conn =
        post(conn, "/api/issues/#{issue.id}/execution-policy/decide", %{
          "decision" => "approve",
          "decided_by" => Ecto.UUID.generate()
        })

      assert json_response(conn, 200)
      body = json_response(conn, 200)
      assert body["status"] == "done"
    end

    test "returns 401 when current_user is not the current participant", %{
      conn: conn,
      company: company
    } do
      {:ok, executor} =
        Agents.create_agent(%{name: "Exec", role: :engineer, company_id: company.id})

      {:ok, policy} =
        ExecutionPolicies.create_execution_policy(%{
          "name" => "Unauthorized Decide Test",
          "company_id" => company.id,
          "stage_configs" => [
            %{"type" => "executor", "participant_id" => executor.id},
            %{"type" => "approver", "participant_id" => Ecto.UUID.generate()}
          ]
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Unauthorized Decide Test",
          description: "Test",
          company_id: company.id
        })

      {:ok, assigned} = Issues.assign_execution_policy(issue, policy.id, executor.id)
      {:ok, _at_approver} = Issues.transition_issue(assigned, :in_review, executor.id)

      conn =
        post(conn, "/api/issues/#{issue.id}/execution-policy/decide", %{
          "decision" => "approve",
          "decided_by" => executor.id
        })

      assert json_response(conn, 401)["errors"]["detail"] == "Unauthorized"
    end
  end
end
