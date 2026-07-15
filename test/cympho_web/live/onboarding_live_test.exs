defmodule CymphoWeb.OnboardingLiveTest do
  use CymphoWeb.LiveCase, async: true

  import Phoenix.LiveViewTest

  alias Cympho.Companies

  describe "Onboarding wizard" do
    test "walks the wizard and launches a company with owner, engineers, and runtime", %{
      conn: conn
    } do
      {:ok, view, html} = live(conn, "/onboarding")
      assert html =~ "Start an autonomous company"
      assert html =~ "Step 1 of 6"

      # welcome -> blueprint
      html = view |> element("button", "Continue") |> render_click()
      assert html =~ "Company blueprint"

      view
      |> form("#blueprint-form", company: %{"blueprint" => "software"})
      |> render_change()

      # blueprint -> company
      view |> element("button", "Continue") |> render_click()

      view
      |> form("#company-step-form",
        company: %{
          "name" => "Wizard Co",
          "goal_title" => "Ship the wizard",
          "issue_prefix" => "WIZ"
        }
      )
      |> render_change()

      # company -> team
      html = view |> element("button", "Continue") |> render_click()
      assert html =~ "Always created."
      assert html =~ "Adapter"

      view
      |> form("#team-step-form",
        company: %{
          "engineer_count" => "2",
          "engineer_names" => ["Ada", "Grace"],
          "adapter" => "claude_code",
          "runtime_command" => "cz",
          "runtime_model" => "claude-sonnet-5"
        }
      )
      |> render_change()

      # team -> launch
      html = view |> element("button", "Continue") |> render_click()
      assert html =~ "Launch autonomous company"
      assert html =~ "Ada"

      html = view |> element("button", "Launch autonomous company") |> render_click()
      assert html =~ "all set!"
      assert html =~ "Enter Cympho"

      company = Companies.get_company_by_slug("wizard-co")
      assert company

      # The signed-in LiveCase user must own the new company. list_memberships/1
      # preloads :user, so identity is assertable without a LiveCase helper.
      assert [membership] = Companies.list_memberships(company.id)
      assert membership.role == "owner"
      assert membership.is_board_member
      assert membership.user.email =~ "live-user-"

      agents = Companies.list_company_agents(company.id)
      engineer_names = agents |> Enum.filter(&(&1.role == :engineer)) |> Enum.map(& &1.name)
      assert Enum.sort(engineer_names) == ["Ada", "Grace"]

      for agent <- agents do
        assert agent.runtime_config["command"] == "cz"
        assert agent.runtime_config["env"]["ANTHROPIC_MODEL"] == "claude-sonnet-5"
      end

      # A second launch click is ignored: a duplicate would get slug wizard-co-1.
      render_click(view, "start_autonomous_company")
      assert Companies.get_company_by_slug("wizard-co-1") == nil
    end

    test "blocks the company step on an invalid issue prefix", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/onboarding")

      view |> element("button", "Continue") |> render_click()
      view |> element("button", "Continue") |> render_click()

      view
      |> form("#company-step-form",
        company: %{"name" => "Bad Prefix Co", "issue_prefix" => "bad"}
      )
      |> render_change()

      html = view |> element("button", "Continue") |> render_click()
      assert html =~ "Issue prefix must be 2-7 uppercase letters."
      assert html =~ "Step 3 of 6"
    end

    test "blocks the company step when the goal is blank", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/onboarding")

      view |> element("button", "Continue") |> render_click()
      view |> element("button", "Continue") |> render_click()

      view
      |> form("#company-step-form",
        company: %{"name" => "Goalless Co", "goal_title" => "   ", "issue_prefix" => "GOAL"}
      )
      |> render_change()

      html = view |> element("button", "Continue") |> render_click()
      assert html =~ "Company goal is required."
      assert html =~ "Step 3 of 6"
    end

    test "shows the error banner when the launch transaction fails", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/onboarding")

      # A 256-char goal passes the wizard's blank check but fails
      # Goal.changeset's max-255 validation inside the launch transaction.
      render_change(view, "update_company_form", %{
        "company" => %{
          "name" => "Banner Co",
          "goal_title" => String.duplicate("g", 256),
          "issue_prefix" => "BAN"
        }
      })

      html = render_click(view, "start_autonomous_company")
      assert html =~ "Could not create company:"
      assert Companies.get_company_by_slug("banner-co") == nil
    end

    test "coerces a tampered adapter to claude_code", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/onboarding")

      # The <select> constrains the browser, not the client: push the change
      # event directly, as a tampered payload would.
      render_change(view, "update_company_form", %{
        "company" => %{"name" => "Tamper Co", "issue_prefix" => "TMP", "adapter" => "process"}
      })

      render_click(view, "start_autonomous_company")

      company = Companies.get_company_by_slug("tamper-co")
      assert company

      for agent <- Companies.list_company_agents(company.id) do
        assert agent.adapter == :claude_code
      end
    end

    test "changing the blueprint refills goal and prefix", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/onboarding")

      view |> element("button", "Continue") |> render_click()

      view
      |> form("#blueprint-form", company: %{"blueprint" => "go_to_market"})
      |> render_change()

      html = view |> element("button", "Continue") |> render_click()
      assert html =~ ~s(value="GTM")
      assert html =~ "Launch a repeatable go-to-market motion for the offer"
    end

    test "skip navigates users who already have a company", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/onboarding")

      assert {:error, {:live_redirect, %{to: "/issues"}}} =
               view |> element("button", "Skip setup") |> render_click()
    end

    test "skip is refused while the user has no company" do
      {:ok, user} =
        Cympho.Users.create_user(%{
          email: "wizard-solo-#{System.unique_integer([:positive])}@example.com",
          name: "Wizard Solo",
          password: "password1234"
        })

      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session(:user_id, user.id)

      {:ok, view, _html} = live(conn, "/onboarding")

      html = render_click(view, "skip")
      assert html =~ "Finish setup to enter Cympho."
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
