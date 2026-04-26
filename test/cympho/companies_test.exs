defmodule Cympho.CompaniesTest do
  use Cympho.DataCase

  alias Cympho.Companies
  alias Cympho.Companies.{Company, CompanyInvite, JoinRequest}

  describe "companies" do
    test "create_company/1 with valid data creates a company" do
      attrs = %{name: "Test Corp", slug: "test-corp"}
      assert {:ok, %Company{} = company} = Companies.create_company(attrs)
      assert company.name == "Test Corp"
      assert company.slug == "test-corp"
    end

    test "create_company/1 with logo_url" do
      attrs = %{name: "Logo Corp", slug: "logo-corp", logo_url: "https://example.com/logo.png"}
      assert {:ok, %Company{} = company} = Companies.create_company(attrs)
      assert company.logo_url == "https://example.com/logo.png"
    end

    test "create_company/1 with invalid slug returns error" do
      attrs = %{name: "Bad", slug: "INVALID SLUG!"}
      assert {:error, changeset} = Companies.create_company(attrs)

      assert "must contain only lowercase letters, numbers, and hyphens" in errors_on(changeset).slug
    end

    test "create_company/1 with duplicate slug returns error" do
      Companies.create_company(%{name: "First", slug: "dup-slug"})
      assert {:error, changeset} = Companies.create_company(%{name: "Second", slug: "dup-slug"})
      assert "has already been taken" in errors_on(changeset).slug
    end

    test "get_company_by_slug/1 returns company by slug" do
      {:ok, company} = Companies.create_company(%{name: "Slug Corp", slug: "slug-corp"})
      assert Companies.get_company_by_slug("slug-corp").id == company.id
    end
  end

  describe "invites" do
    setup do
      {:ok, company} = Companies.create_company(%{name: "Invite Corp", slug: "invite-corp"})

      {:ok, user} =
        Cympho.Authentication.register_user(%{
          email: "inviter@test.com",
          name: "Inviter",
          password: "password123"
        })

      {:ok, company: company, user: user}
    end

    test "create_invite/1 creates a pending invite", %{company: company, user: user} do
      attrs = %{
        "company_id" => company.id,
        "inviter_id" => user.id,
        "email" => "new@test.com",
        "role" => "member"
      }

      assert {:ok, %CompanyInvite{} = invite} = Companies.create_invite(attrs)
      assert invite.token != nil
      assert invite.status == "pending"
      assert invite.expires_at != nil
    end

    test "accept_invite/2 creates membership", %{company: company, user: user} do
      attrs = %{
        "company_id" => company.id,
        "inviter_id" => user.id,
        "email" => "new@test.com",
        "role" => "member"
      }

      {:ok, invite} = Companies.create_invite(attrs)

      {:ok, new_user} =
        Cympho.Authentication.register_user(%{
          email: "new@test.com",
          name: "New",
          password: "password123"
        })

      assert {:ok, _} = Companies.accept_invite(invite.token, new_user.id)
      assert Companies.has_access?(new_user.id, company.id)
    end

    test "accept_invite/2 with expired token returns error", %{company: company, user: user} do
      expired = DateTime.add(DateTime.utc_now(), -1, :second)

      invite = %CompanyInvite{
        company_id: company.id,
        inviter_id: user.id,
        email: "expired@test.com",
        token: "expired-token",
        status: "pending",
        expires_at: expired
      }

      {:ok, invite} = Repo.insert(invite)

      assert {:error, :expired} = Companies.accept_invite("expired-token", user.id)
    end
  end

  describe "join requests" do
    setup do
      {:ok, company} = Companies.create_company(%{name: "Join Corp", slug: "join-corp"})

      {:ok, user} =
        Cympho.Authentication.register_user(%{
          email: "joiner@test.com",
          name: "Joiner",
          password: "password123"
        })

      {:ok, company: company, user: user}
    end

    test "create_join_request/1 creates pending request", %{company: company, user: user} do
      assert {:ok, %JoinRequest{} = req} =
               Companies.create_join_request(%{
                 company_id: company.id,
                 user_id: user.id,
                 message: "Please let me in"
               })

      assert req.status == "pending"
    end

    test "approve_join_request/2 creates membership", %{company: company, user: user} do
      {:ok, req} = Companies.create_join_request(%{company_id: company.id, user_id: user.id})
      assert {:ok, _} = Companies.approve_join_request(req, user.id)
      assert Companies.has_access?(user.id, company.id)
    end

    test "reject_join_request/2 keeps user out", %{company: company, user: user} do
      {:ok, req} = Companies.create_join_request(%{company_id: company.id, user_id: user.id})
      assert {:ok, _} = Companies.reject_join_request(req, user.id)
      refute Companies.has_access?(user.id, company.id)
    end
  end

  describe "export/import" do
    test "export_company/1 scrubs secret fields" do
      {:ok, company} = Companies.create_company(%{name: "Export Corp", slug: "export-corp"})
      data = Companies.export_company(company.id)

      assert data.company.logo_url == nil
      refute data.company[:password_hash]
    end

    test "import_company/1 creates new company from exported data" do
      {:ok, company} = Companies.create_company(%{name: "Source Corp", slug: "source-corp"})
      data = Companies.export_company(company.id)

      assert {:ok, result} = Companies.import_company(data)
      assert result.company.name == "Source Corp"
      assert result.company.slug =~ "source-corp"
      assert result.company.id != company.id
    end

    test "import_company/1 handles slug collision with suffix strategy" do
      {:ok, _existing} = Companies.create_company(%{name: "Existing", slug: "collide-corp"})
      {:ok, company} = Companies.create_company(%{name: "Source", slug: "collide-corp"})
      data = Companies.export_company(company.id)

      assert {:ok, result} = Companies.import_company(data, slug_strategy: :suffix)
      assert result.company.slug != "collide-corp"
      assert String.contains?(result.company.slug, "collide-corp")
    end
  end
end
