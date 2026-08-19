defmodule Cympho.Issues.TenantAssociationsTest do
  use Cympho.DataCase, async: true

  alias Cympho.{
    Agents,
    Companies,
    ExecutionPolicies,
    Goals,
    HeartbeatEngine,
    Issues,
    Projects,
    Users,
    Workspaces
  }

  setup do
    unique = System.unique_integer([:positive])

    {:ok, company} =
      Companies.create_company(%{
        name: "Issue scope A #{unique}",
        slug: "issue-scope-a-#{unique}"
      })

    {:ok, other_company} =
      Companies.create_company(%{
        name: "Issue scope B #{unique}",
        slug: "issue-scope-b-#{unique}"
      })

    {:ok, project} =
      Projects.create_project(%{
        name: "Issue scope project A",
        prefix: "ISA",
        company_id: company.id
      })

    {:ok, other_project} =
      Projects.create_project(%{
        name: "Issue scope project B",
        prefix: "ISB",
        company_id: other_company.id
      })

    {:ok, issue} =
      Issues.create_issue(%{
        title: "Scoped issue A",
        company_id: company.id,
        project_id: project.id
      })

    {:ok, other_issue} =
      Issues.create_issue(%{
        title: "Scoped issue B",
        company_id: other_company.id,
        project_id: other_project.id
      })

    {:ok, other_goal} =
      Goals.create_goal(%{
        title: "Foreign goal",
        company_id: other_company.id,
        project_id: other_project.id
      })

    {:ok, agent} =
      Agents.create_agent(%{
        name: "Issue scope agent A",
        role: :engineer,
        company_id: company.id,
        project_id: project.id
      })

    {:ok, other_agent} =
      Agents.create_agent(%{
        name: "Issue scope agent B",
        role: :engineer,
        company_id: other_company.id,
        project_id: other_project.id
      })

    {:ok, other_policy} =
      ExecutionPolicies.create_execution_policy(%{
        name: "Foreign execution policy",
        company_id: other_company.id,
        stage_configs: []
      })

    {:ok, other_workspace} =
      Workspaces.create_project_workspace(%{
        name: "Foreign project workspace",
        company_id: other_company.id,
        project_id: other_project.id
      })

    {:ok, other_execution_workspace} =
      Workspaces.create_execution_workspace(%{
        name: "Foreign execution workspace",
        company_id: other_company.id,
        project_id: other_project.id,
        project_workspace_id: other_workspace.id,
        source_issue_id: other_issue.id
      })

    {:ok, other_user} =
      Users.create_user(%{
        name: "Foreign issue user",
        email: "foreign-issue-#{unique}@example.com",
        password: "password1234"
      })

    {:ok, _membership} =
      Companies.create_membership(%{
        company_id: other_company.id,
        user_id: other_user.id,
        role: "member"
      })

    {:ok, sibling_issue} =
      Issues.create_issue(%{
        title: "Run owner issue",
        company_id: company.id,
        project_id: project.id,
        assignee_id: agent.id
      })

    {:ok, sibling_run} =
      HeartbeatEngine.create_run(%{
        company_id: company.id,
        agent_id: agent.id,
        issue_id: sibling_issue.id,
        adapter: "process"
      })

    %{
      issue: issue,
      company: company,
      other_company: other_company,
      other_project: other_project,
      other_issue: other_issue,
      other_goal: other_goal,
      other_agent: other_agent,
      other_policy: other_policy,
      other_workspace: other_workspace,
      other_execution_workspace: other_execution_workspace,
      other_user: other_user,
      sibling_run: sibling_run
    }
  end

  test "rejects cross-company domain associations", context do
    rejected = [
      {:project_id, context.other_project.id},
      {:goal_id, context.other_goal.id},
      {:assignee_id, context.other_agent.id},
      {:created_by_agent_id, context.other_agent.id},
      {:last_reviewer_id, context.other_agent.id},
      {:parent_id, context.other_issue.id},
      {:execution_policy_id, context.other_policy.id},
      {:project_workspace_id, context.other_workspace.id},
      {:execution_workspace_id, context.other_execution_workspace.id}
    ]

    for {field, value} <- rejected do
      assert {:error, changeset} = Issues.update_issue(context.issue, %{field => value})
      assert Keyword.has_key?(changeset.errors, field), "expected an error on #{field}"
    end
  end

  test "rejects user references without membership in the issue company", context do
    for field <- [:assignee_user_id, :created_by_user_id] do
      assert {:error, changeset} =
               Issues.update_issue(context.issue, %{field => context.other_user.id})

      assert Keyword.has_key?(changeset.errors, field)
    end
  end

  test "rejects a checkout run owned by another issue", context do
    assert {:error, changeset} =
             Issues.update_issue(context.issue, %{checkout_run_id: context.sibling_run.id})

    assert Keyword.has_key?(changeset.errors, :checkout_run_id)
  end

  test "prevents moving an existing issue to another company", context do
    assert {:error, changeset} =
             Issues.update_issue(context.issue, %{company_id: context.other_company.id})

    assert Keyword.has_key?(changeset.errors, :company_id)
    assert Issues.get_issue!(context.issue.id).company_id == context.company.id
  end
end
