defmodule CymphoWeb.OnboardingLiveTest do
  use CymphoWeb.LiveCase, async: true

  import Phoenix.LiveViewTest

  alias Cympho.Companies

  describe "Onboarding page" do
    test "creates a company from a selected blueprint", %{conn: conn} do
      {:ok, view, html} = live(conn, "/onboarding")

      assert html =~ "Start an autonomous company"
      assert html =~ "Cympho turns a company goal into an operating loop"
      refute html =~ "Cympho runs like Paperclip"

      html =
        view
        |> element("button", "Continue")
        |> render_click()

      assert html =~ "Company blueprint"
      assert html =~ "Go-to-market company"
      assert html =~ "Product discovery company"
      assert html =~ "QA and release company"
      assert html =~ "Community growth company"
      assert html =~ "Security compliance company"
      assert html =~ "Training academy company"
      assert html =~ "agents"
      assert html =~ "capabilities"

      html =
        view
        |> form("#company-starter-form",
          company: %{
            "blueprint" => "go_to_market",
            "name" => "Live Growth Blueprint",
            "goal_title" => "Build and run the business autonomously",
            "issue_prefix" => "LLM",
            "engineer_count" => "1"
          }
        )
        |> render_change()

      assert html =~ "Launch a repeatable go-to-market motion for the offer"
      assert html =~ ~s(value="GTM")

      html =
        view
        |> form("#company-starter-form",
          company: %{
            "blueprint" => "go_to_market",
            "name" => "Live Growth Blueprint",
            "goal_title" => "Launch a repeatable go-to-market motion for the offer",
            "issue_prefix" => "GTM",
            "engineer_count" => "1"
          }
        )
        |> render_submit()

      assert html =~ "Your autonomous company is ready"
      assert html =~ "Go-to-market company"
      assert html =~ "Growth OS"
      assert html =~ "Manifest"
      assert html =~ "agents ·"
      assert html =~ "capabilities"
      assert html =~ "Product Manager"
      assert html =~ "Sales Development"
      refute html =~ "Product_manager"
      refute html =~ "Sales_development"

      company = Companies.get_company_by_slug("live-growth-blueprint")
      assert company.governance_config["company_blueprint"] == "go_to_market"
      assert company.governance_config["company_blueprint_manifest"]["agent_count"] == 10
      assert company.governance_config["company_blueprint_manifest"]["seed_issue_count"] == 5

      roles =
        company.id
        |> Companies.list_company_agents()
        |> Enum.map(& &1.role)

      assert :marketer in roles
      assert :sales_development in roles
      assert :customer_support in roles
    end

    test "filters the larger blueprint catalog", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/onboarding")

      html =
        view
        |> element("button", "Continue")
        |> render_click()

      assert html =~ "17 of 17"

      html =
        view
        |> form("#blueprint-search-form", blueprint_query: "security")
        |> render_change()

      assert html =~ "Security compliance company"
      assert html =~ "1 of 17"
      refute html =~ "Training academy company"

      html =
        view
        |> form("#blueprint-search-form", blueprint_query: "training")
        |> render_change()

      assert html =~ "Training academy company"
      assert html =~ "1 of 17"
      refute html =~ "Security compliance company"
    end
  end
end
