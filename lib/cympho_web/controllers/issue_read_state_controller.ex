defmodule CymphoWeb.IssueReadStateController do
  use CymphoWeb, :controller
  alias Cympho.IssueReadStates
  alias Cympho.UserAuthJWT

  action_fallback CymphoWeb.FallbackController

  def mark_read(conn, %{"issue_id" => issue_id}) do
    with {:ok, user_id} <- extract_user_id(conn),
         {:ok, _state} <- IssueReadStates.mark_read(user_id, issue_id) do
      json(conn, %{data: %{status: "ok"}})
    else
      {:error, :no_auth} ->
        unauthorized(conn, "Missing authentication")

      {:error, :invalid_token} ->
        unauthorized(conn, "Invalid or expired token")

      error ->
        error
    end
  end

  def mark_all_read(conn, _params) do
    with {:ok, user_id} <- extract_user_id(conn),
         {:ok, count} <- IssueReadStates.mark_all_read(user_id) do
      json(conn, %{data: %{status: "ok", count: count}})
    else
      {:error, :no_auth} ->
        unauthorized(conn, "Missing authentication")

      {:error, :invalid_token} ->
        unauthorized(conn, "Invalid or expired token")

      error ->
        error
    end
  end

  def get_read_state(conn, %{"issue_id" => issue_id}) do
    with {:ok, user_id} <- extract_user_id(conn),
         state = IssueReadStates.get_read_state_or_default(user_id, issue_id),
         {_, new_comments} <- IssueReadStates.get_unread_comments(user_id, issue_id) do
      json(conn, %{
        data: %{
          last_read_at: state.last_read_at,
          last_read_comment_id: state.last_read_comment_id,
          unread_count: length(new_comments)
        }
      })
    else
      {:error, :no_auth} ->
        unauthorized(conn, "Missing authentication")

      {:error, :invalid_token} ->
        unauthorized(conn, "Invalid or expired token")

      error ->
        error
    end
  end

  defp extract_user_id(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        case UserAuthJWT.verify_token(token) do
          {:ok, claims} ->
            case UserAuthJWT.get_user_id(claims) do
              {:ok, user_id} -> {:ok, user_id}
              _ -> {:error, :invalid_token}
            end

          _ ->
            {:error, :invalid_token}
        end

      _ ->
        {:error, :no_auth}
    end
  end

  defp unauthorized(conn, message) do
    conn
    |> put_status(:unauthorized)
    |> json(%{errors: [%{detail: message}]})
    |> halt()
  end
end
