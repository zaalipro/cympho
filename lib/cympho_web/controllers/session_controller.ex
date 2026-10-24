defmodule CymphoWeb.SessionController do
  use CymphoWeb, :controller

  import Ecto.Query

  require Logger

  alias Cympho.Authentication
  alias Cympho.Companies
  alias Cympho.Companies.CompanyMembership
  alias Cympho.RateLimiting.LoginRateLimiter
  alias Cympho.Repo
  alias Cympho.Users
  alias Cympho.Users.User
  alias CymphoWeb.ClientIP
  alias CymphoWeb.Endpoint
  alias CymphoWeb.UserAuth

  @dev Mix.env() == :dev

  def new(conn, params) do
    if Repo.aggregate(User, :count) == 0 do
      # Fresh instance: no owner yet — send the visitor to first-run setup
      # instead of a login form nobody can pass.
      redirect(conn, to: "/setup")
    else
      return_to = UserAuth.safe_return_path(params["return_to"])

      conn
      |> put_root_layout(html: {CymphoWeb.AuthHTML, :root})
      |> put_layout(false)
      |> put_view(html: CymphoWeb.AuthHTML)
      |> render(:login,
        page_title: "Sign in",
        email: text(params["email"]),
        return_to: return_to,
        error: Phoenix.Flash.get(conn.assigns.flash, :error),
        dev_login_href: dev_login_href(return_to)
      )
    end
  end

  def create(conn, %{"user" => %{"email" => email, "password" => password}})
      when is_binary(email) and is_binary(password) do
    return_to = UserAuth.safe_return_path(conn.params["return_to"]) || "/"
    client_ip = ClientIP.from_conn(conn)

    with :ok <- LoginRateLimiter.check(client_ip),
         {:ok, %User{} = user} <- Authentication.authenticate_user(email, password) do
      LoginRateLimiter.record_success(client_ip)

      conn
      |> sign_in(user)
      |> put_flash(:info, "Signed in")
      |> redirect(to: return_to)
    else
      {:error, :rate_limited} ->
        Logger.warning("sign-in throttled", component: "session_controller")

        conn
        |> put_flash(:error, "Too many failed sign-in attempts. Try again in a few minutes.")
        |> redirect(to: "/login")

      {:error, :invalid_credentials} ->
        conn
        |> put_flash(:error, "Invalid email or password")
        |> redirect(to: "/login")
    end
  end

  def create(conn, _params) do
    conn
    |> put_flash(:error, "Email and password are required")
    |> redirect(to: "/login")
  end

  def delete(conn, _params) do
    with user_id when is_binary(user_id) <- get_session(conn, :user_id),
         {:ok, user} <- Users.get_user(user_id),
         true <- Users.session_version_valid?(get_session(conn, :session_version), user),
         {:ok, _user} <- Users.revoke_sessions(user) do
      # Signed cookie sessions and user JWTs are otherwise valid until their
      # expiration. Incrementing the persisted version makes sign-out an
      # immediate all-sessions revocation point.
      disconnect_user_sockets(user_id, get_session(conn, :company_id))
    end

    conn
    |> configure_session(drop: true)
    |> redirect(to: "/login")
  end

  def sign_in(conn, %User{} = user) do
    conn
    |> configure_session(renew: true)
    |> put_session(:user_id, user.id)
    |> put_session(:session_version, user.session_version || 0)
    |> put_session(:live_socket_id, live_socket_id(user.id))
    |> put_session(:company_id, default_company_id(user))
    |> seed_theme_cookie(user)
  end

  defp disconnect_user_sockets(user_id, session_company_id) do
    Endpoint.broadcast(live_socket_id(user_id), "disconnect", %{})

    company_ids =
      [
        session_company_id
        | Enum.map(Companies.list_memberships_for_user(user_id), & &1.company_id)
      ]
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    Enum.each(company_ids, fn company_id ->
      Endpoint.broadcast("socket:#{company_id}:#{user_id}", "disconnect", %{})
    end)
  end

  defp live_socket_id(user_id), do: "users_sessions:#{user_id}"

  # Mirror the user's saved theme into a (non-HttpOnly) cookie so the root
  # layout server-renders the right `data-theme` on the next request and the
  # ThemeManager JS hook can read/update it client-side. Non-sensitive value.
  defp seed_theme_cookie(conn, %User{} = user) do
    put_resp_cookie(conn, "theme", Cympho.Themes.normalize(user.theme),
      max_age: 60 * 60 * 24 * 365,
      http_only: false,
      same_site: "Lax"
    )
  end

  defp default_company_id(%User{} = user) do
    if is_binary(user.company_id) and Companies.has_access?(user.id, user.company_id) do
      user.company_id
    else
      Repo.one(
        from(m in CompanyMembership,
          where: m.user_id == ^user.id,
          order_by: [asc: m.inserted_at, asc: m.id],
          select: m.company_id,
          limit: 1
        )
      )
    end
  end

  defp dev_login_href(return_to) do
    if @dev do
      case UserAuth.login_path(return_to) do
        "/login" -> "/dev/login"
        "/login?" <> query -> "/dev/login?#{query}"
      end
    end
  end

  defp text(value) when is_binary(value), do: value
  defp text(_), do: nil
end
