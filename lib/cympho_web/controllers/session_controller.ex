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
    conn
    |> put_layout(false)
    |> html(sign_in_page(params, Phoenix.Flash.get(conn.assigns.flash, :error)))
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
        <title>Sign in · Cympho</title>
        <style>
          :root { color-scheme: dark; font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background: #08090f; color: #f4f4f5; }
          body { min-height: 100vh; margin: 0; display: grid; place-items: center; background: radial-gradient(circle at 50% -20%, rgba(94, 106, 210, .28), transparent 34%), #08090f; }
          main { width: min(420px, calc(100vw - 32px)); border: 1px solid rgba(255,255,255,.12); border-radius: 8px; background: rgba(20, 22, 32, .92); box-shadow: 0 24px 80px rgba(0,0,0,.42); }
          form { display: grid; gap: 14px; padding: 28px; }
          h1 { margin: 0; font-size: 24px; line-height: 1.15; font-weight: 650; letter-spacing: 0; }
          p { margin: 0; color: #a1a1aa; font-size: 14px; line-height: 1.5; }
          label { display: grid; gap: 7px; color: #d4d4d8; font-size: 13px; font-weight: 560; }
          input { width: 100%; box-sizing: border-box; border: 1px solid rgba(255,255,255,.12); border-radius: 7px; background: #0d0f18; color: #f4f4f5; padding: 10px 11px; font: inherit; }
          input:focus { outline: 2px solid rgba(94,106,210,.55); outline-offset: 1px; }
          button { border: 0; border-radius: 7px; background: #5e6ad2; color: white; padding: 10px 12px; font: inherit; font-weight: 620; cursor: pointer; }
          button:hover { background: #6d78df; }
          .error { color: #fca5a5; background: rgba(239, 68, 68, .12); border: 1px solid rgba(239, 68, 68, .24); border-radius: 7px; padding: 9px 10px; }
          .dev { color: #71717a; font-size: 12px; }
          a { color: #a5b4fc; text-decoration: none; }
        </style>
      </head>
      <body>
        <main>
          <form method="post" action="/login">
            <input type="hidden" name="_csrf_token" value="#{csrf}">
            #{return_to_input}
            <div>
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
