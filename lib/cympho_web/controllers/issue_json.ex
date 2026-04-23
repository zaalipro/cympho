defmodule CymphoWeb.IssueJSON do
  alias Cympho.Issues.Issue

  def issue_data(%Issue{} = issue) do
    %{
      id: issue.id,
      title: issue.title,
      description: issue.description,
      status: issue.status,
      priority: issue.priority,
      parent_id: issue.parent_id,
      project_id: issue.project_id,
      assignee_id: issue.assignee_id,
      inserted_at: issue.inserted_at,
      updated_at: issue.updated_at
    }
  end
end
