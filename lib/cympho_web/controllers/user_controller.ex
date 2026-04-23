defmodule CymphoWeb.UserController do
  use CymphoWeb, :controller

  alias Cympho.Users
  alias Cympho.Users.User

  action_fallback CymphoWeb.FallbackController

  def index(conn, _params) do
    users = Users.list_users()
    render(conn, :index, users: users)
  end

  def create(conn, %{"user" => user_params}) do
    with {:ok, %User{} = user} <- Users.create_user(user_params) do
      conn
      |> put_status(:created)
      |> render(:show, user: user)
    end
  end

  def show(conn, %{"id" => id}) do
    case Users.get_user(id) do
      {:ok, user} ->
        render(conn, :show, user: user)

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> put_view(json: CymphoWeb.ErrorJSON)
        |> render(:"404")
    end
  end

  def update(conn, %{"id" => id, "user" => user_params}) do
    case Users.get_user(id) do
      {:ok, user} ->
        with {:ok, %User{} = user} <- Users.update_user(user, user_params) do
          render(conn, :show, user: user)
        end

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> put_view(json: CymphoWeb.ErrorJSON)
        |> render(:"404")
    end
  end

  def update_notification_prefs(conn, %{"id" => id, "user" => prefs}) do
    case Users.get_user(id) do
      {:ok, user} ->
        with {:ok, %User{} = user} <- Users.update_notification_prefs(user, prefs) do
          render(conn, :show, user: user)
        end

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> put_view(json: CymphoWeb.ErrorJSON)
        |> render(:"404")
    end
  end

  def delete(conn, %{"id" => id}) do
    case Users.get_user(id) do
      {:ok, user} ->
        Users.delete_user(user)
        send_resp(conn, :no_content, "")

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> put_view(json: CymphoWeb.ErrorJSON)
        |> render(:"404")
    end
  end
end
