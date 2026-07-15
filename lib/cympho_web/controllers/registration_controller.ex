defmodule CymphoWeb.RegistrationController do
  use CymphoWeb, :controller

  alias Cympho.Authentication
  alias Cympho.Users.User

  action_fallback CymphoWeb.FallbackController

  def create(conn, %{"user" => user_params}) do
    if Application.get_env(:cympho, :open_registration, false) do
      do_create(conn, user_params)
    else
      conn
      |> put_status(:forbidden)
      |> json(%{error: "registration is invite-only"})
    end
  end

  defp do_create(conn, user_params) do
    case Authentication.register_user(user_params) do
      {:ok, %User{} = user} ->
        conn
        |> put_status(:created)
        |> render(:show, user: user)

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> put_view(json: CymphoWeb.ErrorJSON)
        |> render(:error, changeset: changeset)
    end
  end
end
