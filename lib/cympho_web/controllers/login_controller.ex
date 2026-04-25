defmodule CymphoWeb.LoginController do
  use CymphoWeb, :controller

  alias Cympho.Authentication

  def create(conn, %{"email" => email, "password" => password}) do
    case Authentication.authenticate_user(email, password) do
      {:ok, user} ->
        # Generate a JWT token for the user
        case Cympho.AgentAuthJWT.generate_token(user.id, nil, user.company_id) do
          {:ok, token} ->
            json(conn, %{
              data: %{
                token: token,
                user: %{
                  id: user.id,
                  email: user.email,
                  name: user.name
                }
              }
            })

          {:error, _reason} ->
            conn
            |> put_status(:internal_server_error)
            |> json(%{error: "Failed to generate token"})
        end

      {:error, :invalid_credentials} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Invalid email or password"})
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Email and password are required"})
  end
end