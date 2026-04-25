defmodule CymphoWeb.RegistrationController do
  use CymphoWeb, :controller

  alias Cympho.Authentication

  def create(conn, %{"user" => user_params}) do
    case Authentication.register_user(user_params) do
      {:ok, user} ->
        conn
        |> put_status(:created)
        |> render(:show, user: user)

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render(:error, changeset: changeset)
    end
  end
end