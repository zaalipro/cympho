defmodule CymphoWeb.ApprovalController do
  use CymphoWeb, :controller
  alias Cympho.{Agents, Issues}
  alias Cympho.Approvals

  action_fallback CymphoWeb.FallbackController

  def index(conn, params) do
    company_id = conn.assigns.current_company.id
    parsed_status = parse_status(Map.get(params, "status"))

    approvals = Approvals.list_approvals(%{status: parsed_status, company_id: company_id})

    json(conn, %{data: Enum.map(approvals, &approval_data/1)})
  end

  def create(conn, %{"approval" => approval_params}) do
    company_id = conn.assigns.current_company.id
    issue_ids = approval_params["issue_ids"] || []

    attrs = %{
      type: approval_params["type"],
      requested_by_agent_id: approval_params["requested_by_agent_id"],
      payload: approval_params["payload"],
      issue_ids: issue_ids
    }

    with :ok <- validate_agent_ref(company_id, attrs.requested_by_agent_id),
         :ok <- validate_issue_refs(company_id, issue_ids) do
      case Approvals.create_approval(attrs) do
        {:ok, approval} ->
          conn
          |> put_status(:created)
          |> json(%{data: approval_data(approval)})

        {:error, changeset} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{errors: format_errors(changeset)})
      end
    end
  end

  def show(conn, %{"id" => id}) do
    company_id = conn.assigns.current_company.id

    with {:ok, approval} <- Approvals.get_company_approval(company_id, id) do
      json(conn, %{data: approval_data(approval)})
    end
  end

  def update(conn, %{"id" => id, "approval" => approval_params}) do
    company_id = conn.assigns.current_company.id

    case approval_params["status"] do
      status when status in ["approved", "denied"] ->
        opts = %{
          resolved_by_user_id: conn.assigns.current_user.id,
          resolution_reason: approval_params["resolution_reason"]
        }

        case Approvals.resolve_company_approval(
               company_id,
               id,
               approval_resolution(status),
               opts
             ) do
          {:ok, approval} ->
            json(conn, %{data: approval_data(approval)})

          {:error, %Ecto.Changeset{} = changeset} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{errors: format_errors(changeset)})

          {:error, :not_pending} ->
            conn
            |> put_status(:conflict)
            |> json(%{error: "approval is no longer pending"})

          {:error, reason} ->
            {:error, reason}
        end

      _status ->
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
    case String.downcase(s) do
      "pending" -> :pending
      "approved" -> :approved
      "denied" -> :denied
      "cancelled" -> :cancelled
      _ -> nil
    end
  end

  defp parse_status(_), do: nil

  defp approval_resolution("approved"), do: :approved
  defp approval_resolution("denied"), do: :denied

  defp validate_agent_ref(_company_id, nil), do: :ok
  defp validate_agent_ref(_company_id, ""), do: :ok

  defp validate_agent_ref(company_id, agent_id) do
    case Agents.get_company_agent(company_id, agent_id) do
      {:ok, _agent} -> :ok
      {:error, _} -> {:error, :not_found}
    end
  end

  defp validate_issue_refs(company_id, issue_ids) do
    if Enum.all?(issue_ids, &company_issue?(company_id, &1)) do
      :ok
    else
      {:error, :not_found}
    end
  end

  defp company_issue?(company_id, issue_id) do
    match?({:ok, _issue}, Issues.get_company_issue(company_id, issue_id))
  end

  defp approval_data(approval) do
    %{
      id: approval.id,
      type: approval.type,
      status: approval.status,
      payload: approval.payload,
      resolution_reason: approval.resolution_reason,
      requested_by_agent_id: approval.requested_by_agent_id,
      resolved_by_user_id: approval.resolved_by_user_id,
      issue_ids: Enum.map(approval.issues, & &1.id),
      inserted_at: approval.inserted_at,
      updated_at: approval.updated_at
    }
  end
end
