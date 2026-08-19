defmodule CymphoWeb.UserAuth do
  @moduledoc """
  Authentication and company context for LiveViews.

  Provides an on_mount hook that:
  - Loads the current user from session
  - Redirects unauthenticated browsers to the login page
  - Determines the current company from session or user default
  - Falls back to first membership company if needed
  - Assigns :current_user, :user_companies, :current_company to socket
  """

  import Phoenix.Component, only: [assign: 3]
  alias Cympho.Companies
  alias Cympho.Users

  def require_authenticated_user(conn, _opts) do
    case Plug.Conn.get_session(conn, :user_id) do
      user_id when is_binary(user_id) ->
        case Users.get_user(user_id) do
          {:ok, user} ->
            if Users.session_version_valid?(Plug.Conn.get_session(conn, :session_version), user) do
              conn
              |> Plug.Conn.assign(:current_user, user)
              |> assign_browser_company_context(user)
              |> sync_theme(user)
            else
              redirect_to_login(conn)
            end

          {:error, :not_found} ->
            redirect_to_login(conn)
        end

      _ ->
        redirect_to_login(conn)
    end
  end

  # Conn-level twin of on_mount(:require_company) for non-LiveView routes.
  def require_company(conn, _opts) do
    case conn.assigns[:current_company] do
      %{id: _} ->
        conn

      _ ->
        conn
        |> Phoenix.Controller.redirect(to: "/onboarding")
        |> Plug.Conn.halt()
    end
  end

  # The DB is the source of truth for an authenticated user's theme. FetchTheme
  # (in the :browser pipeline) renders the `theme` cookie for the first paint,
  # before auth runs; once the user is known we override the assign and re-seed
  # the cookie so a stale or hand-edited cookie can't mask the saved theme.
  defp sync_theme(conn, user) do
    theme = Cympho.Themes.normalize(Map.get(user, :theme))

    conn
    |> Plug.Conn.assign(:theme, theme)
    |> Plug.Conn.put_resp_cookie("theme", theme,
      max_age: 60 * 60 * 24 * 365,
      http_only: false,
      same_site: "Lax"
    )
  end

  def on_mount(:default, _params, session, socket) do
    socket =
      socket
      |> assign_current_user(session)

    if is_nil(socket.assigns.current_user) do
      {:halt, Phoenix.LiveView.redirect(socket, to: "/login")}
    else
      socket =
        socket
        |> assign_user_companies()
        |> assign_current_company(session)
        |> assign_sidebar_data()
        |> subscribe_inbox_badge_updates()
        |> subscribe_approval_badge_updates()
        |> subscribe_owner_attention_updates()

      {:cont, socket}
    end
  end

  # Blocks company-less users from the app proper; they are funneled into
  # /onboarding (its live_session mounts only :default) until they own a
  # company membership. Prevents orphan rows like projects with NULL company.
  def on_mount(:require_company, _params, _session, socket) do
    case socket.assigns[:current_company] do
      %{id: _} -> {:cont, socket}
      _ -> {:halt, Phoenix.LiveView.redirect(socket, to: "/onboarding")}
    end
  end

  def login_path(return_to) do
    case safe_return_path(return_to) do
      nil -> "/login"
      path -> "/login?return_to=#{URI.encode_www_form(path)}"
    end
  end

  def safe_return_path(path) when is_binary(path) do
    cond do
      path == "" ->
        nil

      not String.starts_with?(path, "/") ->
        nil

      String.starts_with?(path, "//") ->
        nil

      # Phoenix refuses backslashes in local redirects because browsers may
      # interpret them as path separators (for example `/\\evil.example`).
      # Reject them here so a crafted return_to falls back instead of raising
      # from redirect/2 with a 500.
      String.contains?(path, ["\\", "\n", "\r", "\t"]) ->
        nil

      true ->
        path
    end
  end

  def safe_return_path(_path), do: nil

  defp redirect_to_login(conn) do
    return_to = current_path(conn)

    conn
    |> Phoenix.Controller.put_flash(:error, "Sign in to continue.")
    |> Phoenix.Controller.redirect(to: login_path(return_to))
    |> Plug.Conn.halt()
  end

  defp current_path(conn) do
    case conn.query_string do
      "" -> conn.request_path
      query -> conn.request_path <> "?" <> query
    end
  end

  defp assign_sidebar_data(socket) do
    case socket.assigns[:current_company] do
      %{id: company_id} ->
        inbox_count = owner_inbox_badge_count(company_id, socket.assigns[:current_user])
        approval_count = pending_approval_badge_count(company_id)

        socket
        |> assign(:nav_projects, Cympho.Projects.list_for_sidebar(company_id))
        |> assign(:nav_agents, Cympho.Agents.list_for_sidebar(company_id))
        |> assign(:nav_goals, Cympho.Goals.list_for_sidebar(company_id))
        |> assign(:nav_inbox_count, inbox_count)
        |> assign(:nav_approval_count, approval_count)
        |> assign(:inbox_badge_count, inbox_count)
        |> assign(:approval_badge_count, approval_count)

      _ ->
        socket
        |> assign(:nav_projects, [])
        |> assign(:nav_agents, [])
        |> assign(:nav_goals, [])
        |> assign(:nav_inbox_count, 0)
        |> assign(:nav_approval_count, 0)
        |> assign(:inbox_badge_count, 0)
        |> assign(:approval_badge_count, 0)
    end
  end

  defp subscribe_inbox_badge_updates(socket) do
    case socket.assigns[:current_company] do
      %{id: company_id} when is_binary(company_id) ->
        if Phoenix.LiveView.connected?(socket) do
          Cympho.Inbox.subscribe_company_badges(company_id)
        end

        Phoenix.LiveView.attach_hook(socket, :inbox_badge_count, :handle_info, fn
          {:company_inbox_count_changed, changed_company_id, _unread_count}, socket
          when changed_company_id == company_id ->
            count = owner_inbox_badge_count(company_id, socket.assigns[:current_user])

            {:halt, put_inbox_badge_counts(socket, count)}

          _message, socket ->
            {:cont, socket}
        end)

      _ ->
        socket
    end
  end

  defp subscribe_approval_badge_updates(socket) do
    case socket.assigns[:current_company] do
      %{id: company_id} when is_binary(company_id) ->
        if Phoenix.LiveView.connected?(socket) do
          Cympho.Approvals.subscribe(company_id)
        end

        Phoenix.LiveView.attach_hook(socket, :approval_badge_count, :handle_info, fn message,
                                                                                     socket ->
          if approval_badge_event?(message) do
            count = pending_approval_badge_count(company_id)
            inbox_count = owner_inbox_badge_count(company_id, socket.assigns[:current_user])

            {:cont,
             socket
             |> assign(:nav_approval_count, count)
             |> assign(:approval_badge_count, count)
             |> assign(:nav_inbox_count, inbox_count)
             |> assign(:inbox_badge_count, inbox_count)
             |> push_nav_badges()}
          else
            {:cont, socket}
          end
        end)

      _ ->
        socket
    end
  end

  defp subscribe_owner_attention_updates(socket) do
    case socket.assigns[:current_company] do
      %{id: company_id} when is_binary(company_id) ->
        if Phoenix.LiveView.connected?(socket) do
          Cympho.OwnerAttention.subscribe(company_id)
        end

        Phoenix.LiveView.attach_hook(socket, :owner_attention_badge_count, :handle_info, fn
          {:owner_attention_changed, changed_company_id}, socket
          when changed_company_id == company_id ->
            count = owner_inbox_badge_count(company_id, socket.assigns[:current_user])
            socket = put_inbox_badge_counts(socket, count)

            if socket.view == CymphoWeb.InboxLive.Index,
              do: {:cont, socket},
              else: {:halt, socket}

          _message, socket ->
            {:cont, socket}
        end)

      _ ->
        socket
    end
  end

  # Root layout chrome is outside LiveView inner_content and does not re-render
  # on assign changes. Keep socket assigns for first paint / LV consumers, and
  # push a client event so desktop + mobile badge DOM update without full nav.
  defp put_inbox_badge_counts(socket, count) when is_integer(count) do
    socket
    |> assign(:nav_inbox_count, count)
    |> assign(:inbox_badge_count, count)
    |> push_nav_badges()
  end

  defp push_nav_badges(socket) do
    inbox = socket.assigns[:inbox_badge_count] || socket.assigns[:nav_inbox_count] || 0
    approval = socket.assigns[:approval_badge_count] || socket.assigns[:nav_approval_count] || 0

    Phoenix.LiveView.push_event(socket, "nav_badges", %{
      inbox: inbox,
      approval: approval
    })
  end

  defp assign_browser_company_context(conn, user) do
    memberships = Companies.list_memberships_for_user(user.id)
    companies = Enum.map(memberships, &company_map(&1.company))
    {conn, company} = resolve_company_for_conn(conn, user, companies)

    conn
    |> Plug.Conn.assign(:user_companies, companies)
    |> Plug.Conn.assign(:current_company, company)
    |> Plug.Conn.assign(:current_company_id, company && company.id)
    |> Plug.Conn.assign(:current_company_role, company && Companies.get_role(user.id, company.id))
    |> Plug.Conn.assign(:runtime_controls_allowed, runtime_control_allowed?(user, company))
    |> assign_browser_sidebar_data(company)
  end

  defp assign_browser_sidebar_data(conn, %{id: company_id}) do
    inbox_count = owner_inbox_badge_count(company_id, conn.assigns[:current_user])
    approval_count = pending_approval_badge_count(company_id)

    conn
    |> Plug.Conn.assign(:nav_projects, Cympho.Projects.list_for_sidebar(company_id))
    |> Plug.Conn.assign(:nav_agents, Cympho.Agents.list_for_sidebar(company_id))
    |> Plug.Conn.assign(:nav_goals, Cympho.Goals.list_for_sidebar(company_id))
    |> Plug.Conn.assign(:nav_inbox_count, inbox_count)
    |> Plug.Conn.assign(:nav_approval_count, approval_count)
    |> Plug.Conn.assign(:inbox_badge_count, inbox_count)
    |> Plug.Conn.assign(:approval_badge_count, approval_count)
  end

  defp assign_browser_sidebar_data(conn, _company) do
    conn
    |> Plug.Conn.assign(:nav_projects, [])
    |> Plug.Conn.assign(:nav_agents, [])
    |> Plug.Conn.assign(:nav_goals, [])
    |> Plug.Conn.assign(:nav_inbox_count, 0)
    |> Plug.Conn.assign(:nav_approval_count, 0)
    |> Plug.Conn.assign(:inbox_badge_count, 0)
    |> Plug.Conn.assign(:approval_badge_count, 0)
  end

  defp pending_approval_badge_count(company_id) do
    Cympho.Approvals.count_pending_for_company(company_id) +
      Cympho.BoardApprovals.count_pending_for_company(company_id)
  end

  # Nav badge = Simple "Needs you" membership (OwnerAttention), not agent unreads.
  # Cheap unresolved_count keeps parity with list_items after issue-level dedup.
  defp owner_inbox_badge_count(company_id, user) do
    min(99, Cympho.OwnerAttention.unresolved_count(company_id, user))
  end

  defp approval_badge_event?({event, _payload})
       when event in [
              :approval_created,
              :approval_resolved,
              :approval_cancelled,
              :approvals_cancelled_for_issue,
              :board_approval_created,
              :board_approval_resolved,
              :board_approval_cancelled,
              :board_vote_cast
            ],
       do: true

  defp approval_badge_event?(_message), do: false

  defp assign_current_user(socket, session) do
    case session["user_id"] do
      nil ->
        assign(socket, :current_user, nil)

      user_id ->
        case Users.get_user(user_id) do
          {:ok, user} ->
            if Users.session_version_valid?(session["session_version"], user) do
              # Store lightweight map instead of full Ecto struct to avoid
              # Jason.Encoder errors in LiveView test mode
              user_map = %{
                id: user.id,
                email: user.email,
                name: user.name,
                company_id: user.company_id,
                theme: user.theme
              }

              assign(socket, :current_user, user_map)
            else
              assign(socket, :current_user, nil)
            end

          {:error, :not_found} ->
            assign(socket, :current_user, nil)
        end
    end
  end

  defp assign_user_companies(socket) do
    user = socket.assigns[:current_user]

    companies =
      if is_nil(user) do
        []
      else
        Companies.list_memberships_for_user(user.id)
        |> Enum.map(& &1.company)
        |> Enum.map(&company_map/1)
      end

    assign(socket, :user_companies, companies)
  end

  defp assign_current_company(socket, session) do
    user = socket.assigns[:current_user]
    companies = socket.assigns[:user_companies]

    company =
      cond do
        is_nil(user) ->
          List.first(companies)

        # Try session company_id first
        session["company_id"] ->
          session_company =
            companies
            |> Enum.find(fn c -> c.id == session["company_id"] end)

          session_company || fallback_company(user, companies)

        # Try user's default company_id
        user.company_id ->
          user_company =
            companies
            |> Enum.find(fn c -> c.id == user.company_id end)

          user_company || fallback_company(user, companies)

        # Fallback to first membership company
        true ->
          List.first(companies)
      end

    socket
    |> assign(:current_company, company)
    |> assign(:current_company_role, company && Companies.get_role(user.id, company.id))
    |> assign(:runtime_controls_allowed, runtime_control_allowed?(user, company))
  end

  defp fallback_company(_user, companies) do
    # If the session company or user default company is not in the user's memberships,
    # fall back to the first company in their memberships
    List.first(companies)
  end

  defp resolve_company_for_conn(conn, user, companies) do
    session_company_id = Plug.Conn.get_session(conn, :company_id)

    cond do
      is_binary(session_company_id) ->
        case Enum.find(companies, &(&1.id == session_company_id)) do
          nil ->
            conn = Plug.Conn.delete_session(conn, :company_id)
            {conn, fallback_company(user, companies)}

          company ->
            {conn, company}
        end

      true ->
        {conn, fallback_company(user, companies)}
    end
  end

  defp company_map(company) do
    %{
      id: company.id,
      name: company.name,
      logo_url: company.logo_url,
      status: company.status,
      paused_at: company.paused_at,
      paused_reason: company.paused_reason,
      governance_config: company.governance_config || %{}
    }
  end

  defp runtime_control_allowed?(%{id: user_id}, %{id: company_id})
       when is_binary(user_id) and is_binary(company_id) do
    Cympho.CompanyRBAC.manager?(user_id, company_id)
  end

  defp runtime_control_allowed?(_user, _company), do: false
end
