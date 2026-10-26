defmodule CymphoWeb.CompanyLiveTest do
  use CymphoWeb.LiveCase, async: false

  import Phoenix.LiveViewTest
  import CymphoWeb.R3PageHelpers

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
      # v7 C5: New company, Import and the guided "Start company setup" are the head's pills.
      assert has_element?(view, ".head .chips a[href='/companies/new']", "New company")
      assert has_element?(view, ".head .chips a[href='/companies/import']", "Import")
      assert has_element?(view, ".head .chips a[href='/onboarding']", "Start company setup")

      assert_r3_page(main_doc(view),
        page: "companies",
        h1: "Companies",
        kind: :deep,
        parent: "Settings",
        primaries: 0
      )

      assert html =~ "Launch autonomous companies from working blueprints"
      assert html =~ "Build from blueprint"
      assert html =~ "Import company"
      assert html =~ "#{blueprint_count}"
      assert html =~ "Blueprint catalog"
      assert html =~ "Default agents"
      assert html =~ "Capabilities"
      assert html =~ "Your companies"
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

    # Review r1: guided setup was Simple mode's way to start a company before the restyle.
    test "Simple mode keeps the guided company setup", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/companies")
      simple = view |> main_doc() |> Floki.filter_out(".ui-advanced-only")

      assert text(simple, ".head .chips a[href='/onboarding']") == "Start company setup"
    end

    test "each company row counts its members and names a status other than active", %{
      conn: conn,
      current_company: company
    } do
      {:ok, colleague} =
        Cympho.Users.create_user(%{
          email: "colleague-#{System.unique_integer([:positive])}@example.com",
          name: "Colleague",
          password: "password1234"
        })

      {:ok, _} =
        Companies.create_membership(%{
          user_id: colleague.id,
          company_id: company.id,
          role: "member"
        })

      {:ok, view, _html} = live(conn, "/companies")
      assert has_element?(view, "#companies-#{company.id} .rm", "2 members")
      refute has_element?(view, "#companies-#{company.id} .lr-tr")

      company |> Ecto.Changeset.change(status: "archived") |> Cympho.Repo.update!()
      {:ok, view, _html} = live(conn, "/companies")
      assert has_element?(view, "#companies-#{company.id} .lr-tr .tag", "Archived")
    end

    test "keeps the plain company form available for manual companies", %{conn: conn} do
      {:ok, view, html} = live(conn, "/companies/new")

      assert html =~ "New company"
      assert has_element?(view, ~s(#company-form input[name="company[name]"]))
      assert has_element?(view, ~s(#company-form input[name="company[slug]"]))
      assert has_element?(view, "#company-form .ink button.pw[type='submit']", "Create company")
      assert has_element?(view, ~s(#company-form .ink a.pd[href="/companies"]), "Cancel")
      refute has_element?(view, ".head .chips a[href='/companies/new']")

      assert_r3_page(main_doc(view),
        page: "companies",
        h1: "Companies",
        kind: :deep,
        parent: "Settings",
        primaries: 1
      )
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

    # Review r1: only an active company can be paused (the old guard was status == "active").
    test "an archived company offers neither Pause nor Resume", %{
      conn: conn,
      current_company: company
    } do
      [membership] = Companies.list_memberships(company.id)
      {:ok, _} = Companies.update_membership(membership, %{role: "owner", is_board_member: true})
      company |> Ecto.Changeset.change(status: "archived") |> Cympho.Repo.update!()

      {:ok, view, _html} = live(conn, "/companies/#{company.id}")

      refute has_element?(view, "[phx-click='show_pause_modal']")
      refute has_element?(view, "[phx-click='show_resume_modal']")
      refute has_element?(view, ".next")
      assert has_element?(view, ".head .chips .tag", "Archived")
    end

    # Review r1: the old page showed the pause reason to everyone who could open it.
    test "a paused company shows its reason to a member who cannot resume it", %{
      conn: conn,
      current_company: company
    } do
      {:ok, paused} = Companies.pause_company(company, "Quarterly audit")

      {:ok, view, _html} = live(conn, "/companies/#{paused.id}")
      doc = main_doc(view)

      assert_r3_page(doc,
        page: "company",
        h1: paused.name,
        kind: :deep,
        parent: "Companies",
        primaries: 0
      )

      assert text(doc, ".next .paper") =~ "Quarterly audit"
      assert text(doc, ".next .paper") =~ "Only owners, admins and board members can resume it."
      assert Floki.find(doc, ".next .ink") == []
      refute has_element?(view, "[phx-click='show_resume_modal']")
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
      refute has_element?(view, "[phx-click='show_pause_modal']")
      refute has_element?(view, ~s(a[href="/companies/#{company.id}/edit"]))
      refute has_element?(view, "[phx-click='delete_membership']")

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

    # v7 C8: Show passed `patch={true}`, so Cancel rendered href="#" and went nowhere.
    test "the edit form's Cancel returns to the company", %{conn: conn, current_company: company} do
      [membership] = Companies.list_memberships(company.id)
      {:ok, _} = Companies.update_membership(membership, %{role: "owner", is_board_member: true})

      {:ok, view, _html} = live(conn, "/companies/#{company.id}/edit")

      assert has_element?(
               view,
               ~s(#company-form .ink a[href="/companies/#{company.id}"]),
               "Cancel"
             )

      refute has_element?(view, ~s(#company-form a[href="#"]))
      # the page is the edit form already: no Edit pill pointing back at it
      refute has_element?(view, ~s(.head .chips a[href="/companies/#{company.id}/edit"]))
    end

    # Render r2: the edit page did not say it was one. Its H1, tab title and crumb now do, as on
    # /budgets/:id/edit (spec P4: H1 "Edit <name>", crumb "Edit …", page_title = H1).
    test "the edit page names itself in the H1, the breadcrumb and the tab title", %{
      conn: conn,
      current_company: company
    } do
      [membership] = Companies.list_memberships(company.id)
      {:ok, _} = Companies.update_membership(membership, %{role: "owner", is_board_member: true})

      {:ok, view, _html} = live(conn, "/companies/#{company.id}/edit")
      doc = main_doc(view)

      assert text(doc, ".crumb [aria-current]") == "Edit company"
      assert texts(doc, "h1") == ["Edit #{company.name}"]
      assert page_title(view) =~ "Edit #{company.name}"

      {:ok, show, _html} = live(conn, "/companies/#{company.id}")

      assert text(main_doc(show), ".crumb [aria-current]") == company.name
      assert texts(main_doc(show), "h1") == [company.name]
      assert page_title(show) =~ company.name
      refute page_title(show) =~ "Edit"
    end

    # v7 §2.6: while editing, the edit pair is the page's only pair and Save its only primary.
    test "a paused company's edit page shows the form, not the Resume step", %{
      conn: conn,
      current_company: company
    } do
      [membership] = Companies.list_memberships(company.id)
      {:ok, _} = Companies.update_membership(membership, %{role: "owner", is_board_member: true})
      {:ok, paused} = Companies.pause_company(company, "Budget review")

      {:ok, view, _html} = live(conn, "/companies/#{paused.id}/edit")
      doc = main_doc(view)

      assert_r3_page(doc,
        page: "company",
        h1: "Edit #{paused.name}",
        kind: :deep,
        parent: "Companies",
        primaries: 1
      )

      assert text(doc, "#company-form .ink .pw") == "Save changes"
      assert Floki.find(doc, ".next:not(form)") == []
      assert text(doc, ".head .chips") =~ "Paused"

      {:ok, show, _html} = live(conn, "/companies/#{paused.id}")
      show_doc = main_doc(show)

      assert_r3_page(show_doc,
        page: "company",
        h1: paused.name,
        kind: :deep,
        parent: "Companies",
        primaries: 1
      )

      assert text(show_doc, ".next .paper .nt") == "Resume #{paused.name}"
      assert text(show_doc, ".next .paper .obj") =~ "Budget review"
      assert Floki.find(show_doc, ~s(.next .ink button.pw[phx-click="show_resume_modal"])) != []
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
