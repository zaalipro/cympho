defmodule CymphoWeb.RegistrationController do
  use CymphoWeb, :controller

  alias Cympho.Authentication
<<<<<<< HEAD

  def create(conn, %{"user" => user_params}) do
    case Authentication.register_user(user_params) do
      {:ok, user} ->
=======
  alias Cympho.Users.User

  action_fallback CymphoWeb.FallbackController

  def create(conn, %{"user" => user_params}) do
    case Authentication.register_user(user_params) do
      {:ok, %User{} = user} ->
>>>>>>> origin/LLM-162
        conn
        |> put_status(:created)
        |> render(:show, user: user)

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
<<<<<<< HEAD
        |> render(:error, changeset: changeset)
    end
  end
end
=======
        |> put_view(json: CymphoWeb.ErrorJSON)
        |> render(:error, changeset: changeset)
    end
  end
end
>>>>>>> origin/LLM-162
