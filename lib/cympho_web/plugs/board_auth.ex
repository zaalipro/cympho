defmodule CymphoWeb.Plugs.BoardAuth do
  @moduledoc """
  Plug ensuring only board members can perform governance mutations.

  Expects :current_user to be present in conn assigns (set by user auth plug).
  Returns 403 for non-board users and logs the denied attempt.
  """

  import Plug.Conn
  alias Cympho.Companies
  alias Cympho.GovernanceAuditLogs

  def init(opts), do: opts

  def call(conn, _opts) do
    user = conn.assigns[:current_user]
    company_id = conn.assigns[:current_company_id]

    cond do
      is_nil(user) ->
        deny(conn, "Authentication required")

      is_nil(company_id) ->
        deny(conn, "Company context required")

      board_members_present?(company_id) and not Companies.is_board_member?(user.id, company_id) ->
        log_denial(conn, user, company_id)
        deny(conn, "Board membership required")

      not board_members_present?(company_id) ->
        log_denial(conn, user, company_id)
        deny(conn, "No board members configured for this company")

      true ->
        conn
    end
  end

  defp board_members_present?(company_id) do
    case Companies.list_board_members(company_id) do
      [] -> false
      _ -> true
    end
  end

  defp log_denial(conn, user, company_id) do
    GovernanceAuditLogs.log_action(
      "guard_denied",
      user,
      "Governance mutation denied: board membership required",
      metadata: %{
        company_id: company_id,
        path: conn.request_path,
        method: conn.method
      },
      ip_address: conn.remote_ip |> :inet.ntoa() |> to_string(),
      user_agent: List.first(get_req_header(conn, "user-agent")) || ""
    )
  end

  defp deny(conn, message) do
    conn
    |> put_status(:forbidden)
    |> Phoenix.Controller.json(%{errors: [%{detail: message}]})
    |> halt()
  end
end
