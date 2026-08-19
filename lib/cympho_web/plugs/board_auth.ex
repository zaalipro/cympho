defmodule CymphoWeb.Plugs.BoardAuth do
  @moduledoc """
  Plug ensuring only board members can perform governance mutations.

  Expects :current_user to be present in conn assigns (set by user auth plug).
  Returns 403 for non-board users and logs the denied attempt.
  """

  import Plug.Conn
  alias Cympho.CompanyRBAC
  alias Cympho.Companies
  alias Cympho.GovernanceAuditLogs

  def init(opts), do: opts

  def call(conn, _opts) do
    user = conn.assigns[:current_user]

    company_id = authorization_company_id(conn)

    cond do
      is_nil(user) ->
        deny(conn, "Authentication required")

      is_nil(company_id) ->
        deny(conn, "Company context required")

      not CompanyRBAC.allowed?(Companies.get_role(user.id, company_id), :write) ->
        log_denial(conn, user, company_id)
        deny(conn, "Writable company role required")

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

  defp authorization_company_id(conn) do
    case action_key(conn) do
      {CymphoWeb.CompanyController, :update_governance_config} ->
        conn.path_params["id"]

      _other_action ->
        case conn.assigns[:current_company] do
          %{id: id} -> id
          _ -> conn.assigns[:current_company_id]
        end
    end
  end

  defp action_key(conn) do
    case {conn.private[:phoenix_controller], conn.private[:phoenix_action]} do
      {controller, action} when not is_nil(controller) and not is_nil(action) ->
        {controller, action}

      _ ->
        case Phoenix.Router.route_info(
               CymphoWeb.Router,
               conn.method,
               conn.request_path,
               conn.host
             ) do
          %{plug: controller, plug_opts: action} -> {controller, action}
          _ -> {nil, nil}
        end
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
