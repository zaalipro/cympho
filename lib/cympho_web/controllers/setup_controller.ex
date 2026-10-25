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
    cond do
      users_exist?() ->
        redirect(conn, to: "/login")

      bootstrap_unavailable?() ->
        bootstrap_unavailable(conn)

      true ->
        render_setup(conn, %{}, %{})
    end
  end

  def create(conn, %{"user" => user_params}) do
    case create_first_user(user_params, conn.params["bootstrap_secret"]) do
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

      {:error, :bootstrap_unavailable} ->
        bootstrap_unavailable(conn)

      {:error, :invalid_bootstrap_secret} ->
        render_setup(
          conn,
          user_params,
          %{bootstrap_secret: "Bootstrap secret is invalid."},
          :forbidden
        )

      {:error, %Ecto.Changeset{} = changeset} ->
        render_setup(conn, user_params, field_errors(changeset))
    end
  end

  def create(conn, _params), do: redirect(conn, to: "/setup")

  defp users_exist?, do: Repo.aggregate(User, :count) > 0

  defp create_first_user(params, submitted_secret) do
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock($1)", [@setup_lock_key])

      if users_exist?() do
        Repo.rollback(:already_configured)
      else
        case authorize_bootstrap(submitted_secret) do
          :ok ->
            # Trim + downcase the email: authenticate_user/2 matches emails
            # byte-for-byte, and a first-run typo ("Nick@Example.com ") would
            # permanently lock out the only owner on an instance that has no
            # password-reset flow.
            case Authentication.register_user(%{
                   "name" => String.trim(params["name"] || ""),
                   "email" =>
                     params["email"] |> to_string() |> String.trim() |> String.downcase(),
                   "password" => params["password"]
                 }) do
              {:ok, user} -> user
              {:error, changeset} -> Repo.rollback(changeset)
            end

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end
    end)
  end

  defp authorize_bootstrap(submitted_secret) do
    config = bootstrap_config()

    if Keyword.get(config, :required, false) do
      case Keyword.get(config, :secret) do
        expected when is_binary(expected) and is_binary(submitted_secret) ->
          if secrets_match?(expected, submitted_secret),
            do: :ok,
            else: {:error, :invalid_bootstrap_secret}

        expected when is_binary(expected) ->
          {:error, :invalid_bootstrap_secret}

        _missing ->
          {:error, :bootstrap_unavailable}
      end
    else
      :ok
    end
  end

  defp secrets_match?(expected, submitted) do
    Plug.Crypto.secure_compare(
      :crypto.hash(:sha256, expected),
      :crypto.hash(:sha256, submitted)
    )
  end

  defp bootstrap_config,
    do: Application.get_env(:cympho, :bootstrap_protection, required: false, secret: nil)

  defp bootstrap_required?, do: Keyword.get(bootstrap_config(), :required, false)

  defp bootstrap_unavailable? do
    bootstrap_required?() and not is_binary(Keyword.get(bootstrap_config(), :secret))
  end

  defp render_setup(conn, params, errors, status \\ :ok) do
    conn
    |> put_status(status)
    |> render_auth(:setup,
      page_title: "Set up",
      name: text(params["name"]),
      email: text(params["email"]),
      errors: errors,
      bootstrap_required: bootstrap_required?()
    )
  end

  defp bootstrap_unavailable(conn) do
    conn
    |> put_resp_header("retry-after", "300")
    |> put_status(:service_unavailable)
    |> render_auth(:setup_locked, page_title: "Setup locked", noindex: true)
  end

  # The signed-out pages draw their own Paper & Ink document (CymphoWeb.AuthHTML).
  defp render_auth(conn, template, assigns) do
    conn
    |> put_root_layout(html: {CymphoWeb.AuthHTML, :root})
    |> put_layout(false)
    |> put_view(html: CymphoWeb.AuthHTML)
    |> render(template, assigns)
  end

  # One message per field, shown under that field (the onboarding error pattern).
  defp field_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Map.new(fn {field, messages} ->
      {field, "#{Phoenix.Naming.humanize(field)} #{Enum.join(messages, ", ")}"}
    end)
  end

  defp text(value) when is_binary(value), do: value
  defp text(_), do: nil
end
