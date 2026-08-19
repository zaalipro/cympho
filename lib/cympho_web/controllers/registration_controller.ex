defmodule CymphoWeb.RegistrationController do
  use CymphoWeb, :controller

  alias Cympho.Authentication
  alias Cympho.Companies
  alias Cympho.Users.User

  action_fallback CymphoWeb.FallbackController

  def create(conn, %{"user" => user_params} = params) do
    case invitation_token(params, user_params) do
      token when is_binary(token) and byte_size(token) > 0 ->
        do_create_from_invite(conn, token, Map.drop(user_params, ["invite_token", "token"]))

      _ ->
        if Application.get_env(:cympho, :open_registration, false) do
          do_create(conn, user_params)
        else
          conn
          |> put_status(:forbidden)
          |> json(%{error: "registration is invite-only"})
        end
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

  defp do_create_from_invite(conn, token, user_params) do
    case Companies.register_from_invite(token, user_params) do
      {:ok, %User{} = user} ->
        conn
        |> put_status(:created)
        |> render(:show, user: user)

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> put_view(json: CymphoWeb.ErrorJSON)
        |> render(:error, changeset: changeset)

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: invite_error(reason)})
    end
  end

  defp invitation_token(params, user_params) do
    params["invite_token"] || params["token"] || user_params["invite_token"] ||
      user_params["token"]
  end

  defp invite_error(:account_exists), do: "account already exists; sign in to accept the invite"
  defp invite_error(:email_mismatch), do: "email does not match invitation"
  defp invite_error(:already_used), do: "invitation has already been used"
  defp invite_error(:expired), do: "invitation has expired"
  defp invite_error(_reason), do: "invitation is invalid"
end
