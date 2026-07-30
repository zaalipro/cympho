defmodule CymphoWeb.OnboardingLiveTest do
  use CymphoWeb.LiveCase, async: true

  import Phoenix.LiveViewTest

  alias Cympho.Companies

  describe "Onboarding wizard" do
    test "walks the wizard and launches a company with owner, engineers, and runtime", %{
      conn: conn
    } do
      {:ok, view, html} = live(conn, "/onboarding")
      assert html =~ "Choose a blueprint"
      assert html =~ "Step 1 of 5"
      assert html =~ "Company blueprint"
      assert html =~ "data-ui-complex-page"
      assert html =~ "onboarding-blueprint-card"
      assert html =~ "onboarding-blueprint-input sr-only"

      document = Floki.parse_document!(html)
      [blueprint_grid] = Floki.find(document, "#blueprint-form > div.grid")
      [blueprint_card | _] = Floki.find(document, ".onboarding-blueprint-card")
      grid_classes = blueprint_grid |> Floki.attribute("class") |> Enum.join(" ")
      card_classes = blueprint_card |> Floki.attribute("class") |> Enum.join(" ")

      assert grid_classes =~ "min-w-0"
      assert grid_classes =~ "grid-cols-1"
      assert card_classes =~ "w-full"
      assert card_classes =~ "min-w-0"
      assert card_classes =~ "max-w-full"

      css = File.read!(Path.join([File.cwd!(), "assets/css/app.css"]))
      assert css =~ ".onboarding-blueprint-card:focus-within"

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
      assert html =~ "Owns the goal, sets direction"
      assert html =~ "AI provider"
      assert html =~ "Choose a different AI per role"

      document = Floki.parse_document!(html)
      [advanced_fields] = Floki.find(document, "[data-testid='onboarding-ai-advanced-fields']")

      assert advanced_fields
             |> Floki.attribute("class")
             |> Enum.join(" ") =~ "ui-advanced-only"

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
      assert html =~ "all set"
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

    test "per-role AI overrides land on the matching agents", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/onboarding")

      render_change(view, "update_company_form", %{
        "company" => %{
          "name" => "Role Mix Co",
          "goal_title" => "Prove per-role runtimes",
          "issue_prefix" => "MIX",
          "adapter" => "claude_code",
          "runtime_model" => "claude-sonnet-5"
        }
      })

      render_click(view, "toggle_role_overrides")

      render_change(view, "update_company_form", %{
        "company" => %{
          "role_runtimes" => %{
            "ceo" => %{"adapter" => "", "model" => "claude-opus-4-8", "command" => ""},
            "cto" => %{"adapter" => "codex", "model" => "gpt-5.5", "command" => ""},
            "engineer" => %{"adapter" => "", "model" => "", "command" => "cz"}
          }
        }
      })

      render_click(view, "start_autonomous_company")

      company = Companies.get_company_by_slug("role-mix-co")
      assert company

      agents = Companies.list_company_agents(company.id)
      ceo = Enum.find(agents, &(&1.role == :ceo))
      cto = Enum.find(agents, &(&1.role == :cto))
      engineer = Enum.find(agents, &(&1.role == :engineer))
      product = Enum.find(agents, &(&1.role == :product_manager))

      # CEO: shared provider, its own model via ANTHROPIC_MODEL
      assert ceo.adapter == :claude_code
      assert ceo.runtime_config["env"]["ANTHROPIC_MODEL"] == "claude-opus-4-8"

      # CTO: different provider; model rides config["model"], not env
      assert cto.adapter == :codex
      assert cto.runtime_config["model"] == "gpt-5.5"
      refute get_in(cto.runtime_config, ["env", "ANTHROPIC_MODEL"])

      # Engineer: blank model falls back to command-only override
      assert engineer.adapter == :claude_code
      assert engineer.runtime_config["command"] == "cz"

      # Non-overridden roles keep the shared runtime
      assert product.adapter == :claude_code
      assert product.runtime_config["env"]["ANTHROPIC_MODEL"] == "claude-sonnet-5"
    end

    test "rejects an OpenAI model under Claude Code before launching", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/onboarding")

      render_change(view, "update_company_form", %{
        "company" => %{
          "name" => "Mismatch Co",
          "goal_title" => "Should not launch",
          "issue_prefix" => "MIS",
          "adapter" => "claude_code",
          "runtime_model" => "gpt-5.5"
        }
      })

      html = render_click(view, "start_autonomous_company")

      # No company is created — the owner is told why instead of launching a
      # company whose agents would silently never dispatch.
      refute Companies.get_company_by_slug("mismatch-co")
      assert html =~ "Claude Code"
      assert html =~ "gpt-5.5"
    end

    test "blocks the company step on an invalid issue prefix", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/onboarding")

      view |> element("button", "Continue") |> render_click()

      view
      |> form("#company-step-form",
        company: %{"name" => "Bad Prefix Co", "issue_prefix" => "bad"}
      )
      |> render_change()

      html = view |> element("button", "Continue") |> render_click()
      assert html =~ "Issue prefix must be 2-7 uppercase letters."
      assert html =~ "Step 2 of 5"
    end

    test "blocks the company step when the goal is blank", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/onboarding")

      view |> element("button", "Continue") |> render_click()

      view
      |> form("#company-step-form",
        company: %{"name" => "Goalless Co", "goal_title" => "   ", "issue_prefix" => "GOAL"}
      )
      |> render_change()

      html = view |> element("button", "Continue") |> render_click()
      assert html =~ "Company goal is required."
      assert html =~ "Step 2 of 5"
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

      assert html =~
               "We couldn&#39;t launch the company. Review the company and AI settings, then try again."

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
      {:ok, view, html} = live(conn, "/onboarding")

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
