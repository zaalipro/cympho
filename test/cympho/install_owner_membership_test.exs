defmodule Cympho.InstallOwnerMembershipTest do
  @moduledoc """
  Covers the install.sh admin seed path: creating a company + admin user must
  also create an owner/board CompanyMembership. UserAuth only lists companies
  via memberships; users.company_id alone must not grant membership.
  """
  use Cympho.DataCase, async: true

  alias Cympho.Companies
  alias Cympho.Repo
  alias Cympho.Users.User

  # Mirrors install.sh seed_admin.exs: create company (no owner_user_id), then
  # admin user with company_id, then ensure_owner_membership!.
  defp install_seed_admin!(attrs) do
    company_name = Map.fetch!(attrs, :company_name)
    issue_prefix = Map.get(attrs, :issue_prefix, "CYM")
    admin_email = Map.fetch!(attrs, :admin_email)
    admin_name = Map.get(attrs, :admin_name, "Install Admin")
    admin_password = Map.get(attrs, :admin_password, "password1234")

    company =
      case Repo.get_by(Companies.Company, name: company_name) do
        nil ->
          {:ok, %{company: company}} =
            Companies.create_autonomous_company(%{
              name: company_name,
              goal_title: "Initial Company Goal",
              issue_prefix: issue_prefix,
              engineer_count: 1,
              adapter: :claude_code
            })

          company

        existing ->
          existing
      end

    user =
      case Repo.get_by(User, email: admin_email) do
        nil ->
          {:ok, user} =
            %User{}
            |> User.registration_changeset(%{
              email: admin_email,
              name: admin_name,
              password: admin_password,
              company_id: company.id
            })
            |> Repo.insert()

          user

        existing ->
          existing
          |> Ecto.Changeset.change(company_id: company.id)
          |> Repo.update!()
      end

    membership = Companies.ensure_owner_membership!(user.id, company.id)
    {user, company, membership}
  end

  describe "install seed path" do
    test "inserts owner + board membership for the admin and lists company for user" do
      email = "install-admin-#{System.unique_integer([:positive])}@example.com"

      {user, company, membership} =
        install_seed_admin!(%{
          company_name: "Install Seed Co #{System.unique_integer([:positive])}",
          admin_email: email
        })

      assert membership.role == "owner"
      assert membership.is_board_member == true
      assert membership.user_id == user.id
      assert membership.company_id == company.id

      reloaded = Companies.get_membership(user.id, company.id)
      assert reloaded.role == "owner"
      assert reloaded.is_board_member

      companies = Companies.list_companies_for_user(user.id)
      assert Enum.map(companies, & &1.id) == [company.id]

      assert Companies.has_access?(user.id, company.id)
      assert Companies.admin?(user.id, company.id)
      assert Companies.is_board_member?(user.id, company.id)
    end

    test "is idempotent when admin already exists" do
      suffix = System.unique_integer([:positive])
      email = "install-idempotent-#{suffix}@example.com"
      company_name = "Install Idempotent Co #{suffix}"

      {user1, company1, m1} =
        install_seed_admin!(%{company_name: company_name, admin_email: email})

      {user2, company2, m2} =
        install_seed_admin!(%{company_name: company_name, admin_email: email})

      assert user1.id == user2.id
      assert company1.id == company2.id
      assert m1.id == m2.id
      assert m2.role == "owner"
      assert m2.is_board_member

      assert length(Companies.list_memberships_for_user(user2.id)) == 1
    end
  end

  describe "company_id alone is not membership" do
    test "user with users.company_id but no CompanyMembership is not a member" do
      {:ok, company} =
        Companies.create_company(%{
          name: "Orphan Link Co",
          slug: "orphan-link-#{System.unique_integer([:positive])}"
        })

      {:ok, user} =
        %User{}
        |> User.registration_changeset(%{
          email: "company-id-only-#{System.unique_integer([:positive])}@example.com",
          name: "Company ID Only",
          password: "password1234"
        })
        |> Ecto.Changeset.put_change(:company_id, company.id)
        |> Repo.insert()

      assert user.company_id == company.id
      assert Companies.get_membership(user.id, company.id) == nil
      assert Companies.list_companies_for_user(user.id) == []
      refute Companies.has_access?(user.id, company.id)
      refute Companies.admin?(user.id, company.id)
      refute Companies.is_board_member?(user.id, company.id)
    end
  end
end
