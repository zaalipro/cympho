defmodule CymphoWeb.CompanyLiveTest do
  use CymphoWeb.LiveCase, async: true

  import Phoenix.LiveViewTest

  alias Cympho.Companies

  describe "company launch console" do
    test "renders blueprint launch posture and company fleet actions", %{
      conn: conn,
      current_company: company
    } do
      {:ok, view, html} = live(conn, "/companies")

      blueprint_count = Companies.autonomous_company_blueprints() |> length()

      assert has_element?(view, "[data-testid='company-launch-command']")
      assert has_element?(view, "[data-testid='company-blueprint-strip']")
      assert has_element?(view, "[data-testid='company-fleet']")
      assert html =~ "Launch autonomous companies from working blueprints"
      assert html =~ "Build from blueprint"
      assert html =~ "Import company"
      assert html =~ "#{blueprint_count}"
      assert html =~ "Blueprint catalog"
      assert html =~ "Company fleet"
      assert html =~ company.name
      assert html =~ ~s(href="/onboarding")
      assert html =~ ~s(href="/companies/import")
      assert html =~ ~s(href="/companies/#{company.id}/export")
      assert html =~ ~s(href="/companies/#{company.id}/edit")

      assert html =~
               "Delete #{company.name}? This removes the company workspace from the fleet and cannot be undone."
    end

    test "keeps the plain company form available for manual companies", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/companies/new")

      assert html =~ "New Company"
      assert html =~ "Company Name"
      assert html =~ "Save Company"
    end

    test "renders specific access and runtime control confirmations", %{
      conn: conn,
      current_company: company
    } do
      [membership] = Companies.list_memberships(company.id)

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
  end
end
