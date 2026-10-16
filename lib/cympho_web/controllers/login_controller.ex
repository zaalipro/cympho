defmodule CymphoWeb.LoginController do
  use CymphoWeb, :controller

  require Logger

  alias Cympho.Authentication
  alias Cympho.Companies
  alias Cympho.RateLimiting.LoginRateLimiter
  alias Cympho.Users.User
  alias Cympho.UserAuthJWT
  alias CymphoWeb.ClientIP

  action_fallback CymphoWeb.FallbackController

  def create(conn, %{"user" => %{"email" => email, "password" => password}})
      when is_binary(email) and is_binary(password) do
    client_ip = ClientIP.from_conn(conn)

    with :ok <- LoginRateLimiter.check(client_ip),
         {:ok, %User{} = user} <- Authentication.authenticate_user(email, password) do
      LoginRateLimiter.record_success(client_ip)
      company_id = Companies.default_company_id_for_user(user)

      case UserAuthJWT.generate_token(user, company_id) do
        {:ok, token} ->
          conn
          |> put_status(:ok)
          |> render(:show, user: user, company_id: company_id, token: token)

        {:error, _reason} ->
          conn
          |> put_status(:internal_server_error)
          |> put_view(json: CymphoWeb.ErrorJSON)
          |> render(:error, message: "Failed to generate token")
      end
    else
      {:error, :rate_limited} ->
        Logger.warning("sign-in throttled", component: "login_controller")

        conn
        |> put_status(:too_many_requests)
        |> put_view(json: CymphoWeb.ErrorJSON)
        |> render(:error,
          message: "Too many failed sign-in attempts. Try again in a few minutes."
        )

      {:error, :invalid_credentials} ->
        conn
        |> put_status(:unauthorized)
        |> put_view(json: CymphoWeb.ErrorJSON)
        |> render(:error, message: "Invalid email or password")
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> put_view(json: CymphoWeb.ErrorJSON)
    |> render(:error, message: "Email and password are required")
  end
end
