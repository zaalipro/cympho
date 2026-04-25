defmodule CymphoWeb.LoginController do
  use CymphoWeb, :controller

  alias Cympho.Authentication
<<<<<<< HEAD

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
=======
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
>>>>>>> origin/LLM-162

          {:error, _reason} ->
            conn
            |> put_status(:internal_server_error)
<<<<<<< HEAD
            |> json(%{error: "Failed to generate token"})
=======
            |> put_view(json: CymphoWeb.ErrorJSON)
            |> render(:error, message: "Failed to generate token")
>>>>>>> origin/LLM-162
        end

      {:error, :invalid_credentials} ->
        conn
        |> put_status(:unauthorized)
<<<<<<< HEAD
        |> json(%{error: "Invalid email or password"})
=======
        |> put_view(json: CymphoWeb.ErrorJSON)
        |> render(:error, message: "Invalid email or password")
>>>>>>> origin/LLM-162
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:bad_request)
<<<<<<< HEAD
    |> json(%{error: "Email and password are required"})
  end
end
=======
    |> put_view(json: CymphoWeb.ErrorJSON)
    |> render(:error, message: "Email and password are required")
  end
end
>>>>>>> origin/LLM-162
