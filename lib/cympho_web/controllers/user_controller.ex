defmodule CymphoWeb.UserController do
  use CymphoWeb, :controller

  alias Cympho.Companies
  alias Cympho.Users
  alias Cympho.Users.User

  action_fallback CymphoWeb.FallbackController

  def index(conn, _params) do
    company_id = conn.assigns.current_company.id

    users =
      Companies.list_memberships(company_id)
      |> Enum.map(& &1.user)

    render(conn, :index, users: users)
  end

  def create(conn, %{"user" => user_params}) do
    company_id = conn.assigns.current_company.id

    with :ok <- require_company_admin(conn.assigns.current_user.id, company_id),
         {:ok, invite} <-
           Companies.create_invite(%{
             company_id: company_id,
             inviter_id: conn.assigns.current_user.id,
             email: user_params["email"] || user_params[:email],
             role: "member"
           }) do
      conn
      |> put_status(:created)
      |> json(%{
        data: %{
          invited: true,
          email: invite.email,
          role: invite.role,
          token: invite.token,
          expires_at: invite.expires_at
        }
      })
    end
  end

  def show(conn, %{"id" => id}) do
    company_id = conn.assigns.current_company.id

    with :ok <- enforce_company_member(company_id, id),
         {:ok, user} <- Users.get_user(id) do
      render(conn, :show, user: user)
    end
  end

  def update(conn, %{"id" => id, "user" => user_params}) do
    with :ok <- enforce_self(conn, id),
         {:ok, user} <- Users.get_user(id),
         {:ok, %User{} = user} <- Users.update_user(user, user_params) do
      render(conn, :show, user: user)
    end
  end

  def update_notification_prefs(conn, %{"id" => id, "user" => prefs}) do
    with :ok <- enforce_self(conn, id),
         {:ok, user} <- Users.get_user(id),
         {:ok, %User{} = user} <- Users.update_notification_prefs(user, prefs) do
      render(conn, :show, user: user)
    end
  end

  def delete(conn, %{"id" => id}) do
    with :ok <- enforce_self(conn, id),
         {:ok, user} <- Users.get_user(id) do
      Users.delete_user(user)
      send_resp(conn, :no_content, "")
    end
  end

  defp enforce_self(conn, id) do
    if conn.assigns.current_user.id == id, do: :ok, else: {:error, :forbidden}
  end

  defp enforce_company_member(company_id, user_id) do
    if Companies.has_access?(user_id, company_id), do: :ok, else: {:error, :not_found}
  end

  defp require_company_admin(user_id, company_id) do
    if Companies.admin?(user_id, company_id), do: :ok, else: {:error, :forbidden}
  end
end
