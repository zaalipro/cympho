defmodule CymphoWeb.LoginController do
  use CymphoWeb, :controller

  alias Cympho.Authentication
  alias Cympho.Users.User
  alias Cympho.UserAuthJWT

  action_fallback CymphoWeb.FallbackController

  def create(conn, %{"user" => %{"email" => email, "password" => password}})
      when is_binary(email) and is_binary(password) do
    case Authentication.authenticate_user(email, password) do
      {:ok, %User{} = user} ->
        case UserAuthJWT.generate_token(user, user.company_id) do
          {:ok, token} ->
            conn
            |> put_status(:ok)
            |> render(:show, user: user, token: token)

          {:error, _reason} ->
            conn
            |> put_status(:internal_server_error)
            |> put_view(json: CymphoWeb.ErrorJSON)
            |> render(:error, message: "Failed to generate token")
        end

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