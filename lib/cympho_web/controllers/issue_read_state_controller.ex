defmodule CymphoWeb.IssueReadStateController do
  use CymphoWeb, :controller
  alias Cympho.{IssueReadStates, Issues}

  action_fallback CymphoWeb.FallbackController

  def mark_read(conn, %{"issue_id" => issue_id}) do
    user_id = conn.assigns.current_user.id

    with {:ok, issue} <- scoped_issue(conn, issue_id),
         {:ok, _state} <- IssueReadStates.mark_read(user_id, issue.id) do
      json(conn, %{data: %{status: "ok"}})
    end
  end

  def mark_all_read(conn, _params) do
    user_id = conn.assigns.current_user.id

    with {:ok, count} <- IssueReadStates.mark_all_read(user_id) do
      json(conn, %{data: %{status: "ok", count: count}})
    end
  end

  def get_read_state(conn, %{"issue_id" => issue_id}) do
    user_id = conn.assigns.current_user.id

    with {:ok, issue} <- scoped_issue(conn, issue_id) do
      state = IssueReadStates.get_read_state_or_default(user_id, issue.id)
      {_, new_comments} = IssueReadStates.get_unread_comments(user_id, issue.id)

      json(conn, %{
        data: %{
          last_read_at: state.last_read_at,
          last_read_comment_id: state.last_read_comment_id,
          unread_count: length(new_comments)
        }
      })
    end
  end

  defp scoped_issue(conn, issue_id) do
    Issues.get_company_issue(conn.assigns.current_company.id, issue_id)
  end
end
