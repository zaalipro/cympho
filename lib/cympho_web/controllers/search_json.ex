defmodule CymphoWeb.SearchJSON do
  alias Cympho.Issues.Issue
  alias Cympho.Comments.Comment

  def results(%{results: results}) do
    %{issues: Enum.map(results.issues, &issue_data/1), comments: Enum.map(results.comments, &comment_data/1)}
  end

  defp issue_data(%Issue{} = issue) do
    %{id: issue.id, title: issue.title, description: String.slice(issue.description || "", 0, 200),
      status: issue.status, priority: issue.priority,
      assignee: issue.assignee && %{id: issue.assignee.id, name: issue.assignee.name},
      inserted_at: issue.inserted_at, updated_at: issue.updated_at}
  end

  defp comment_data(%Comment{} = comment) do
    %{id: comment.id, body: String.slice(comment.body || "", 0, 200), author_type: comment.author_type,
      issue_id: comment.issue_id, issue_title: comment.issue && comment.issue.title, inserted_at: comment.inserted_at}
  end
end
