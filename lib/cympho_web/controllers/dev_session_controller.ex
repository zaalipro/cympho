defmodule CymphoWeb.DevSessionController do
  use CymphoWeb, :controller

  import Ecto.Query

  alias Cympho.Authentication
  alias Cympho.Companies
  alias Cympho.Companies.Company
  alias Cympho.Repo
  alias Cympho.Users
  alias Cympho.Users.User
  alias CymphoWeb.SessionController

  @dev_email "owner@cympho.local"
  @dev_password "password1234"

  def login(conn, _params) do
    user = ensure_dev_owner!()

    conn
    |> SessionController.sign_in(user)
    |> put_flash(:info, "Signed in as local owner")
    |> redirect(to: "/")
  end

  defp ensure_dev_owner! do
    company = first_or_bootstrap_company!()

    user =
      case Users.get_user_by_email(@dev_email) do
        {:ok, %User{} = user} ->
          user

        {:error, :not_found} ->
          {:ok, user} =
            Authentication.register_user(%{
              email: @dev_email,
              name: "Cympho Owner",
              password: @dev_password,
              company_id: company.id
            })

          user
      end

    ensure_membership!(user, company)

    user
    |> Ecto.Changeset.change(company_id: company.id)
    |> Repo.update!()
  end

  defp first_or_bootstrap_company! do
    Repo.one(from(c in Company, order_by: [asc: c.inserted_at, asc: c.name], limit: 1)) ||
      bootstrap_company!()
  end

  defp bootstrap_company! do
    {:ok, %{company: company}} =
      Companies.create_autonomous_company(%{
        name: "Cympho Labs",
        goal_title: "Build an autonomous business operating system for AI teams",
        issue_prefix: "CYM",
        engineer_count: 3,
        adapter: :claude_code
      })

    company
  end

  defp ensure_membership!(%User{id: user_id}, %Company{id: company_id}) do
    case Companies.get_membership(user_id, company_id) do
      nil ->
        Companies.create_membership!(%{
          user_id: user_id,
          company_id: company_id,
          role: "owner",
          is_board_member: true
        })

      membership ->
        membership
        |> Companies.update_membership(%{role: "owner", is_board_member: true})
        |> case do
          {:ok, _membership} ->
            :ok

          {:error, changeset} ->
            raise Ecto.InvalidChangesetError, action: :update, changeset: changeset
        end
    end
  end
end
