defmodule Cympho.AgentActionsTest do
  use Cympho.DataCase, async: false

  alias Cympho.{AgentActions, Comments, Companies, Issues}

  describe "parse/1" do
    test "parses a valid cympho-actions block" do
      body = """
      Delegated.

      ```cympho-actions
      {"actions":[{"type":"comment","body":"Done"}]}
      ```
      """

      assert {:ok, [%{"type" => "comment", "body" => "Done"}]} = AgentActions.parse(body)
    end

    test "rejects missing action block" do
      assert {:error, :missing_action_block} = AgentActions.parse("Done")
    end

    test "rejects unsupported actions" do
      body = """
      ```cympho-actions
      {"actions":[{"type":"ship_money"}]}
      ```
      """

      assert {:error, {:unsupported_action, "ship_money"}} = AgentActions.parse(body)
    end
  end

  describe "execute/3" do
    setup do
      {:ok,
       %{
         company: company,
         project: project,
         goal: goal,
         agents: [ceo, cto, engineer | _],
         first_issue: issue
       }} =
        Companies.create_autonomous_company(%{
          name: "Action Test Company #{System.unique_integer([:positive])}",
          issue_prefix: "ACT",
          engineer_count: 1
        })

      {:ok, issue} = Issues.checkout_issue(issue, ceo, :ceo)

      %{
        company: company,
        project: project,
        goal: goal,
        ceo: ceo,
        cto: cto,
        engineer: engineer,
        issue: issue
      }
    end

    test "create_issue inherits company context and audit fields", %{
      issue: issue,
      cto: cto,
      company: company,
      project: project,
      goal: goal
    } do
      actions = [
        %{
          "type" => "create_issue",
          "title" => "Build action executor",
          "description" => "Implement executor tests.",
          "role" => "engineer",
          "priority" => "high"
        }
      ]

      assert {:ok, %{results: [%{type: "create_issue", issue_id: created_id}]}} =
               AgentActions.execute(issue, cto, actions)

      created = Issues.get_issue!(created_id)
      assert created.company_id == company.id
      assert created.project_id == project.id
      assert created.goal_id == goal.id
      assert created.parent_id == issue.id
      assert created.created_by_agent_id == cto.id
      assert created.origin_type == "agent_action"
      assert created.origin_id == issue.id
      assert created.request_depth == issue.request_depth + 1
      assert created.assigned_role == "engineer"
      assert created.priority == :high
      assert created.status == :todo
    end

    test "submit_review releases current issue to reviewer role", %{issue: issue, ceo: ceo} do
      actions = [%{"type" => "submit_review", "role" => "cto", "notes" => "Ready"}]

      assert {:ok, _} = AgentActions.execute(issue, ceo, actions)

      updated = Issues.get_issue!(issue.id)
      assert updated.status == :in_review
      assert updated.assignee_id == nil
      assert updated.assigned_role == "cto"
    end

    test "approve_issue marks issue done and clears checkout", %{issue: issue, ceo: ceo} do
      actions = [%{"type" => "approve_issue", "notes" => "Approved"}]

      assert {:ok, _} = AgentActions.execute(issue, ceo, actions)

      updated = Issues.get_issue!(issue.id)
      assert updated.status == :done
      assert updated.assignee_id == nil
      assert updated.checked_out_at == nil
    end

    test "request_changes reopens issue for target role", %{issue: issue, cto: cto} do
      actions = [%{"type" => "request_changes", "role" => "engineer", "reason" => "Needs tests"}]

      assert {:ok, _} = AgentActions.execute(issue, cto, actions)

      updated = Issues.get_issue!(issue.id)
      assert updated.status == :todo
      assert updated.assignee_id == nil
      assert updated.assigned_role == "engineer"
    end

    test "block_issue blocks and comments with reason", %{issue: issue, ceo: ceo} do
      actions = [%{"type" => "block_issue", "reason" => "Missing API key"}]

      assert {:ok, _} = AgentActions.execute(issue, ceo, actions)

      updated = Issues.get_issue!(issue.id)
      comments = Comments.list_comments(issue.id)

      assert updated.status == :blocked
      assert updated.assignee_id == nil
      assert Enum.any?(comments, &(&1.body == "Missing API key"))
    end
  end
end
