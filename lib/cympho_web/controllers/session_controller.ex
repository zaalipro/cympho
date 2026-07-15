defmodule CymphoWeb.SessionController do
  use CymphoWeb, :controller

  import Ecto.Query

  alias Cympho.Authentication
  alias Cympho.Companies.CompanyMembership
  alias Cympho.Repo
  alias Cympho.Users.User
  alias CymphoWeb.UserAuth

  @dev Mix.env() == :dev

  def new(conn, params) do
    if Repo.aggregate(User, :count) == 0 do
      # Fresh instance: no owner yet — send the visitor to first-run setup
      # instead of a login form nobody can pass.
      redirect(conn, to: "/setup")
    else
      conn
      |> put_layout(false)
      |> html(sign_in_page(params, Phoenix.Flash.get(conn.assigns.flash, :error)))
    end
  end

  def create(conn, %{"user" => %{"email" => email, "password" => password}})
      when is_binary(email) and is_binary(password) do
    return_to = UserAuth.safe_return_path(conn.params["return_to"]) || "/"

    case Authentication.authenticate_user(email, password) do
      {:ok, %User{} = user} ->
        conn
        |> sign_in(user)
        |> put_flash(:info, "Signed in")
        |> redirect(to: return_to)

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
    conn
    |> configure_session(drop: true)
    |> redirect(to: "/login")
  end

  def sign_in(conn, %User{} = user) do
    conn
    |> configure_session(renew: true)
    |> put_session(:user_id, user.id)
    |> put_session(:company_id, default_company_id(user))
    |> seed_theme_cookie(user)
  end

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

  defp default_company_id(%User{company_id: company_id}) when is_binary(company_id),
    do: company_id

  defp default_company_id(%User{id: user_id}) do
    Repo.one(
      from(m in CompanyMembership,
        where: m.user_id == ^user_id,
        order_by: [asc: m.inserted_at, asc: m.id],
        select: m.company_id,
        limit: 1
      )
    )
  end

  defp sign_in_page(params, error) do
    email = params["email"] || ""
    return_to = UserAuth.safe_return_path(params["return_to"])
    return_to_input = hidden_return_to_input(return_to)
    csrf = Plug.CSRFProtection.get_csrf_token()
    error_html = if error, do: ~s(<p class="error">#{escape(error)}</p>), else: ""

    """
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <link rel="icon" type="image/svg+xml" href="/images/favicon.svg">
        <title>Sign in · Cympho</title>
        <style>
          :root { color-scheme: dark; font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background: #20201E; color: #FAF9F5; }
          body { min-height: 100dvh; margin: 0; display: grid; place-items: center; background: radial-gradient(900px 480px at 50% -120px, rgba(217, 119, 87, .18), transparent 70%), #20201E; }
          main { width: min(420px, calc(100vw - 32px)); border: 1px solid rgba(255,250,245,.10); border-radius: 20px; background: rgba(38, 38, 36, .96); box-shadow: inset 0 1px 0 0 rgba(255,250,245,.05), 0 24px 80px rgba(0,0,0,.42); animation: enter 700ms cubic-bezier(0.16,1,0.3,1) both; }
          @keyframes enter { from { opacity: 0; transform: translateY(14px) scale(.98); } to { opacity: 1; transform: none; } }
          @media (prefers-reduced-motion: reduce) { main { animation: none; } }
          form { display: grid; gap: 14px; padding: 30px; }
          .mark { display: inline-flex; align-items: center; gap: 8px; color: #D97757; font-size: 13px; font-weight: 620; letter-spacing: .08em; text-transform: uppercase; }
          .mark svg { width: 14px; height: 14px; }
          h1 { margin: 6px 0 0; font-family: "Source Serif 4", Georgia, "Times New Roman", serif; font-size: 27px; line-height: 1.15; font-weight: 600; letter-spacing: -0.3px; }
          p { margin: 6px 0 0; color: #B0A99C; font-size: 14px; line-height: 1.5; }
          label { display: grid; gap: 7px; color: #E5E1D8; font-size: 13px; font-weight: 560; }
          input { width: 100%; box-sizing: border-box; border: 1px solid rgba(255,250,245,.12); border-radius: 10px; background: #2D2C2A; color: #FAF9F5; padding: 10px 11px; font: inherit; transition: border-color 160ms ease, box-shadow 160ms ease; }
          input:focus { outline: none; border-color: rgba(217,119,87,.75); box-shadow: 0 0 0 3px rgba(217,119,87,.22); }
          button { border: 0; border-radius: 10px; background: #D97757; color: #20201E; padding: 11px 12px; font: inherit; font-weight: 620; cursor: pointer; box-shadow: inset 0 1px 0 0 rgba(255,255,255,.18); transition: background 160ms ease, box-shadow 400ms cubic-bezier(0.32,0.72,0,1), transform 260ms cubic-bezier(0.32,0.72,0,1); }
          button:hover { background: #E08A6B; box-shadow: inset 0 1px 0 0 rgba(255,255,255,.22), 0 0 24px 2px rgba(217,119,87,.35); transform: translateY(-1px); }
          button:active { transform: translateY(0) scale(.98); }
          .error { color: #E0AEAE; background: rgba(198, 69, 69, .12); border: 1px solid rgba(198, 69, 69, .26); border-radius: 8px; padding: 9px 10px; }
          .dev { color: #8C857A; font-size: 12px; }
          a { color: #E08A6B; text-decoration: none; }
        </style>
      </head>
      <body>
        <main>
          <form method="post" action="/login">
            <input type="hidden" name="_csrf_token" value="#{csrf}">
            #{return_to_input}
            <div>
              <span class="mark">
                <svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M12 2 L13.8 10.2 L22 12 L13.8 13.8 L12 22 L10.2 13.8 L2 12 L10.2 10.2 Z"/></svg>
                Cympho
              </span>
              <h1>Sign in to Cympho</h1>
              <p>Enter the company cockpit with your real projects, agents, and approvals.</p>
            </div>
            #{error_html}
            <label>
              Email
              <input name="user[email]" type="email" autocomplete="email" value="#{escape(email)}" required>
            </label>
            <label>
              Password
              <input name="user[password]" type="password" autocomplete="current-password" required>
            </label>
            <button type="submit">Sign in</button>
            #{dev_shortcut(return_to)}
          </form>
        </main>
      </body>
    </html>
    """
  end

  defp dev_shortcut(return_to) do
    if @dev do
      href =
        case UserAuth.login_path(return_to) do
          "/login" -> "/dev/login"
          "/login?" <> query -> "/dev/login?#{query}"
        end

      ~s(<p class="dev">Local dev: <a href="#{escape(href)}">enter seeded company</a></p>)
    else
      ""
    end
  end

  defp hidden_return_to_input(nil), do: ""

  defp hidden_return_to_input(return_to) do
    ~s(<input type="hidden" name="return_to" value="#{escape(return_to)}">)
  end

  defp escape(value) when is_binary(value),
    do: Phoenix.HTML.html_escape(value) |> Phoenix.HTML.safe_to_string()

  defp escape(_), do: ""
end
