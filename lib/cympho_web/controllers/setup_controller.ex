defmodule CymphoWeb.SetupController do
  @moduledoc """
  One-time first-run setup: creates the instance owner when the user table is
  empty, then hands off to /onboarding. Locks itself permanently once any user
  exists (guarded by a Postgres advisory lock against concurrent submits).
  """

  use CymphoWeb, :controller

  alias Cympho.Authentication
  alias Cympho.Repo
  alias Cympho.Users.User
  alias CymphoWeb.SessionController

  @setup_lock_key 7_214_001

  def new(conn, _params) do
    if users_exist?() do
      redirect(conn, to: "/login")
    else
      conn |> put_layout(false) |> html(setup_page(%{}, nil))
    end
  end

  def create(conn, %{"user" => user_params}) do
    case create_first_user(user_params) do
      {:ok, user} ->
        conn
        |> SessionController.sign_in(user)
        |> put_flash(:info, "Welcome! Let's set up your company.")
        |> redirect(to: "/onboarding")

      {:error, :already_configured} ->
        # A double-submitted form loses the race against itself: the first
        # request signed the owner in, so send the second to onboarding
        # instead of stranding a signed-in user on the login form.
        if get_session(conn, :user_id) do
          redirect(conn, to: "/onboarding")
        else
          redirect(conn, to: "/login")
        end

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_layout(false)
        |> html(setup_page(user_params, first_error(changeset)))
    end
  end

  def create(conn, _params), do: redirect(conn, to: "/setup")

  defp users_exist?, do: Repo.aggregate(User, :count) > 0

  defp create_first_user(params) do
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock($1)", [@setup_lock_key])

      if users_exist?() do
        Repo.rollback(:already_configured)
      else
        # Trim + downcase the email: authenticate_user/2 matches emails
        # byte-for-byte, and a first-run typo ("Nick@Example.com ") would
        # permanently lock out the only owner on an instance that has no
        # password-reset flow.
        case Authentication.register_user(%{
               "name" => String.trim(params["name"] || ""),
               "email" => params["email"] |> to_string() |> String.trim() |> String.downcase(),
               "password" => params["password"]
             }) do
          {:ok, user} -> user
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end
    end)
  end

  defp first_error(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map(fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
    |> List.first()
  end

  defp setup_page(params, error) do
    csrf = Plug.CSRFProtection.get_csrf_token()
    error_html = if error, do: ~s(<p class="error">#{escape(error)}</p>), else: ""

    """
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <link rel="icon" type="image/svg+xml" href="/images/favicon.svg">
        <title>Set up · Cympho</title>
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
          button { border: 0; border-radius: 10px; background: #D97757; color: #20201E; padding: 11px 12px; font: inherit; font-weight: 620; cursor: pointer; box-shadow: inset 0 1px 0 0 rgba(255,255,255,.18); transition: background 160ms ease; }
          button:hover { background: #E08A6B; }
          .error { color: #E0AEAE; background: rgba(198, 69, 69, .12); border: 1px solid rgba(198, 69, 69, .26); border-radius: 8px; padding: 9px 10px; }
        </style>
      </head>
      <body>
        <main>
          <form method="post" action="/setup">
            <input type="hidden" name="_csrf_token" value="#{csrf}">
            <div>
              <span class="mark">
                <svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M12 2 L13.8 10.2 L22 12 L13.8 13.8 L12 22 L10.2 13.8 L2 12 L10.2 10.2 Z"/></svg>
                Cympho
              </span>
              <h1>Create your owner account</h1>
              <p>This instance is brand new. Create the owner account, then the setup wizard will launch your first autonomous company.</p>
            </div>
            #{error_html}
            <label>
              Name
              <input name="user[name]" type="text" autocomplete="name" value="#{escape(params["name"])}" required>
            </label>
            <label>
              Email
              <input name="user[email]" type="email" autocomplete="email" value="#{escape(params["email"])}" required>
            </label>
            <label>
              Password
              <input name="user[password]" type="password" autocomplete="new-password" minlength="8" required>
            </label>
            <button type="submit">Create owner account</button>
          </form>
        </main>
      </body>
    </html>
    """
  end

  defp escape(value) when is_binary(value),
    do: Phoenix.HTML.html_escape(value) |> Phoenix.HTML.safe_to_string()

  defp escape(_), do: ""
end
