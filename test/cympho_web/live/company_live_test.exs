defmodule CymphoWeb.CompanyLiveTest do
  use CymphoWeb.LiveCase, async: false

  import Phoenix.LiveViewTest

  alias Cympho.Companies

  describe "company launch console" do
    test "renders blueprint launch posture and company fleet actions", %{
      conn: conn,
      current_company: company
    } do
      [membership] = Companies.list_memberships(company.id)
      {:ok, _membership} = Companies.update_membership(membership, %{role: "owner"})

      {:ok, view, html} = live(conn, "/companies")

      blueprint_count = Companies.autonomous_company_blueprints() |> length()

      assert has_element?(view, "[data-testid='company-launch-command']")
      assert has_element?(view, "[data-testid='company-blueprint-strip']")
      assert has_element?(view, "[data-testid='company-fleet']")
      assert has_element?(view, "[data-ui-complex-page]")
      assert has_element?(view, "a.ui-simple-only[href='/onboarding']", "Guided setup")
      assert has_element?(view, "a.ui-advanced-only[href='/companies/new']", "New company")
      assert has_element?(view, "a.ui-advanced-only[href='/companies/import']", "Import")
      assert html =~ "Launch autonomous companies from working blueprints"
      assert html =~ "Build from blueprint"
      assert html =~ "Import company"
      assert html =~ "#{blueprint_count}"
      assert html =~ "Blueprint catalog"
      assert html =~ "Default agents"
      assert html =~ "Capabilities"
      assert html =~ "Company fleet"
      assert html =~ company.name
      assert html =~ ~s(href="/onboarding")
      assert html =~ ~s(href="/companies/import")
      assert html =~ ~s(href="/companies/#{company.id}/export")
      assert html =~ ~s(href="/companies/#{company.id}/edit")

      assert html =~
               "Delete #{company.name}? This removes the company workspace from the fleet and cannot be undone."
    end

    test "lists only companies the user belongs to and rejects a forged delete", %{
      conn: conn
    } do
      {:ok, foreign_company} =
        Companies.create_company(%{
          name: "Foreign Fleet Company",
          slug: "foreign-fleet-#{System.unique_integer([:positive])}"
        })

      {:ok, view, html} = live(conn, "/companies")

      refute html =~ foreign_company.name

      html = render_click(view, "delete_company", %{"id" => foreign_company.id})

      assert html =~ "Company not found or you cannot manage it."
      assert Companies.get_company!(foreign_company.id).name == foreign_company.name
    end

    test "keeps the plain company form available for manual companies", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/companies/new")

      assert html =~ "New Company"
      assert html =~ "Company Name"
      assert html =~ "Save Company"
    end

    test "manual company creation keeps the creator as an owner", %{conn: conn} do
      user_id = Plug.Conn.get_session(conn, :user_id)
      {:ok, view, _html} = live(conn, "/companies/new")

      view
      |> form("#company-form",
        company: %{name: "Manual Browser Co", slug: "manual-browser-co"}
      )
      |> render_submit()

      company = Companies.get_company_by_slug("manual-browser-co")
      assert company

      switch_path =
        "/switch-company/#{company.id}?return_to=/companies/#{company.id}"

      assert_redirect(view, switch_path)

      switched_conn = get(conn, switch_path)
      assert redirected_to(switched_conn) == "/companies/#{company.id}"
      assert Plug.Conn.get_session(switched_conn, :company_id) == company.id

      membership = Companies.get_membership(user_id, company.id)
      assert membership.role == "owner"
      assert membership.is_board_member

      assert {:ok, user} = Cympho.Users.get_user(user_id)
      assert user.company_id == company.id
    end

    test "renders specific access and runtime control confirmations", %{
      conn: conn,
      current_company: company
    } do
      [membership] = Companies.list_memberships(company.id)
      {:ok, membership} = Companies.update_membership(membership, %{role: "owner"})

      {:ok, view, html} = live(conn, "/companies/#{company.id}")

      assert html =~
               "Remove #{membership.user.email} from #{company.name}? They will lose access to this company."

      pause_html = render_click(view, "show_pause_modal")

      assert pause_html =~
               "Pause #{company.name}? This stops agent dispatch and new runtime launches until the company is resumed."

      {:ok, paused} = Companies.pause_company(company, "test pause")
      {:ok, resumed_view, _html} = live(conn, "/companies/#{paused.id}")

      resume_html = render_click(resumed_view, "show_resume_modal")

      assert resume_html =~
               "Resume #{company.name}? This re-enables agent dispatch for this company."
    end

    test "redirects users away from a company they cannot access", %{conn: conn} do
      {:ok, foreign_company} =
        Companies.create_company(%{
          name: "Private Foreign Company",
          slug: "private-foreign-#{System.unique_integer([:positive])}"
        })

      assert {:error, {:redirect, %{to: "/companies"}}} =
               live(conn, "/companies/#{foreign_company.id}")
    end

    test "members cannot mutate company membership or runtime", %{
      conn: conn,
      current_company: company
    } do
      [membership] = Companies.list_memberships(company.id)

      {:ok, _membership} =
        Companies.update_membership(membership, %{role: "member", is_board_member: false})

      {:ok, view, html} = live(conn, "/companies/#{company.id}")

      refute html =~ "Pause Company"
      refute html =~ "Edit Company"
      refute html =~ ">Remove<"

      html = render_click(view, "pause_company")
      assert html =~ "You cannot control this company&#39;s runtime."
      assert Companies.get_company!(company.id).status == "active"

      html = render_click(view, "delete_membership", %{"id" => membership.id})
      assert html =~ "Membership not found"
      assert Companies.get_membership(membership.user_id, company.id)
    end

    test "an open company view honors manager demotion for every sensitive event", %{
      conn: conn,
      current_company: company
    } do
      [membership] = Companies.list_memberships(company.id)

      {:ok, membership} =
        Companies.update_membership(membership, %{role: "owner", is_board_member: true})

      {:ok, view, _html} = live(conn, "/companies/#{company.id}")

      {:ok, _demoted} =
        Companies.update_membership(membership, %{role: "member", is_board_member: false})

      html = render_click(view, "show_pause_modal")
      assert html =~ "You cannot control this company&#39;s runtime."

      render_click(view, "pause_company")
      assert Companies.get_company!(company.id).status == "active"

      html = render_click(view, "delete_membership", %{"id" => membership.id})
      assert html =~ "Membership not found"
      assert Companies.get_membership(membership.user_id, company.id)

      {:ok, _paused} = Companies.pause_company(company, "authorization test setup")

      html = render_click(view, "show_resume_modal")
      assert html =~ "You cannot control this company&#39;s runtime."

      render_click(view, "resume_company")
      assert Companies.get_company!(company.id).status == "paused"
    end

    test "an open company view honors membership removal", %{
      conn: conn,
      current_company: company
    } do
      [membership] = Companies.list_memberships(company.id)

      {:ok, membership} =
        Companies.update_membership(membership, %{role: "owner", is_board_member: true})

      {:ok, view, _html} = live(conn, "/companies/#{company.id}")
      {:ok, _deleted} = Companies.delete_membership(membership)

      render_click(view, "pause_company")

      assert Companies.get_company!(company.id).status == "active"
    end

    test "an open company edit form honors manager demotion", %{
      conn: conn,
      current_company: company
    } do
      [membership] = Companies.list_memberships(company.id)

      {:ok, membership} =
        Companies.update_membership(membership, %{role: "owner", is_board_member: true})

      {:ok, view, _html} = live(conn, "/companies/#{company.id}/edit")

      {:ok, _demoted} =
        Companies.update_membership(membership, %{role: "member", is_board_member: false})

      view
      |> form("#company-form", company: %{name: "Unauthorized Rename", slug: company.slug})
      |> render_submit()

      assert Companies.get_company!(company.id).name == company.name
    end
  end
end
