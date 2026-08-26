defmodule CymphoWeb.Plugs.CompanyRBAC do
  @moduledoc """
  Applies the current company's role policy to authenticated human requests.

  Safe requests are readable by every company role, ordinary mutations require
  `member`, and destructive or security-sensitive actions require `admin`.
  Target-company checks stay in resource/controller plugs such as
  `CompanyAccess`.
  """

  import Plug.Conn

  alias Cympho.CompanyRBAC

  @safe_methods ~w(GET HEAD OPTIONS)

  @personal_actions MapSet.new([
                      {CymphoWeb.UserController, :update},
                      {CymphoWeb.UserController, :update_notification_prefs},
                      {CymphoWeb.UserController, :delete},
                      {CymphoWeb.IssueReadStateController, :mark_read},
                      {CymphoWeb.IssueReadStateController, :mark_all_read},
                      {CymphoWeb.CompanyController, :accept_invite},
                      {CymphoWeb.CompanyController, :create}
                    ])

  # CompanyController resolves the company named in the path itself. Skipping
  # it here preserves its 404-on-cross-tenant behavior; CompanyAccess applies
  # the same policy against that resolved target.
  @target_company_controller CymphoWeb.CompanyController

  # These actions enforce a stronger role-or-board capability check against a
  # freshly loaded membership in the target context/controller or the later
  # board pipeline.
  @self_authorizing_actions MapSet.new([
                              {CymphoWeb.ApprovalController, :update},
                              {CymphoWeb.BudgetController, :delete},
                              {CymphoWeb.RuntimeControlController, :low_power},
                              {CymphoWeb.RuntimeControlController, :pause},
                              {CymphoWeb.RuntimeControlController, :stop},
                              {CymphoWeb.RuntimeControlController, :resume}
                            ])

  @admin_actions MapSet.new([
                   {CymphoWeb.UserController, :create},
                   {CymphoWeb.ApprovalController, :create},
                   {CymphoWeb.IssueExecutionPolicyController, :assign},
                   {CymphoWeb.IssueExecutionPolicyController, :decide},
                   {CymphoWeb.DocumentController, :rollback},
                   {CymphoWeb.RoutineController, :archive},
                   {CymphoWeb.RoutineTriggerController, :rotate_secret},
                   {CymphoWeb.WorkspaceController, :seed_worktree},
                   {CymphoWeb.WorkspaceController, :inject_secrets},
                   {CymphoWeb.WorkspaceController, :stop_service},
                   {CymphoWeb.WorkspaceController, :restart_service}
                 ])

  def init(opts), do: opts

  def call(conn, opts) do
    case required_access(conn, opts) do
      :none ->
        conn

      access ->
        role = conn.assigns[:current_company_role]

        if CompanyRBAC.allowed?(role, access), do: conn, else: forbidden(conn)
    end
  end

  def required_access(conn, opts \\ []) do
    key = action_key(conn)

    cond do
      access = Keyword.get(opts, :access) -> access
      exempt?(key) -> :none
      MapSet.member?(@self_authorizing_actions, key) -> :none
      elem(key, 0) == @target_company_controller -> :none
      conn.method in @safe_methods -> :read
      MapSet.member?(@admin_actions, key) -> :admin
      conn.method == "DELETE" -> :admin
      true -> :write
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

  defp exempt?(key), do: MapSet.member?(@personal_actions, key)

  defp forbidden(conn) do
    if html_request?(conn) do
      conn
      |> Phoenix.Controller.put_flash(:error, "Your company role does not allow that action.")
      |> Phoenix.Controller.redirect(to: "/")
      |> halt()
    else
      conn
      |> put_status(:forbidden)
      |> Phoenix.Controller.json(%{errors: [%{detail: "Forbidden"}]})
      |> halt()
    end
  end

  defp html_request?(conn) do
    conn
    |> get_req_header("accept")
    |> Enum.any?(&String.contains?(&1, "text/html"))
  end
end
