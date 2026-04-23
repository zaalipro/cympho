defmodule CymphoWeb.ApprovalController do
  use CymphoWeb, :controller
  alias Cympho.Approvals

  action_fallback CymphoWeb.FallbackController

  def index(conn, params) do
    status = Map.get(params, "status")
    parsed_status = parse_status(status)
    approvals = Approvals.list_approvals(%{status: parsed_status})
    json(conn, %{data: approvals})
  end

  def create(conn, %{"approval" => approval_params}) do
    attrs = %{
      type: approval_params["type"],
      requested_by_agent_id: approval_params["requested_by_agent_id"],
      payload: approval_params["payload"],
      issue_ids: approval_params["issue_ids"] || []
    }

    case Approvals.create_approval(attrs) do
      {:ok, approval} ->
        conn
        |> put_status(:created)
        |> json(%{data: approval})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  def show(conn, %{"id" => id}) do
    case Approvals.get_approval(id) do
      {:ok, approval} ->
        json(conn, %{data: approval})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "not found"})
    end
  end

  def update(conn, %{"id" => id, "approval" => approval_params}) do
    status = approval_params["status"]

    if status in ["approved", "denied"] do
      opts = %{
        resolved_by_user_id: approval_params["resolved_by_user_id"],
        resolution_reason: approval_params["resolution_reason"]
      }

      case Approvals.resolve_approval(id, String.to_atom(status), opts) do
        {:ok, approval} ->
          json(conn, %{data: approval})

        {:error, changeset} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{errors: format_errors(changeset)})
      end
    else
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{error: "status must be approved or denied"})
    end
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp parse_status(nil), do: nil
  defp parse_status(""), do: nil
  defp parse_status(s) when is_binary(s) do
    case s |> String.downcase() |> String.to_atom() do
      status when status in [:pending, :approved, :denied, :cancelled] -> status
      _ -> nil
    end
  end
  defp parse_status(_), do: nil
end
