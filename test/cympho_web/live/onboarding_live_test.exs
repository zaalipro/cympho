defmodule CymphoWeb.OnboardingLiveTest do
  use CymphoWeb.LiveCase, async: true

  import Phoenix.LiveViewTest

  alias Cympho.Companies
  alias Cympho.Companies.Company
  alias Cympho.Goals
  alias Cympho.Issues
  alias Cympho.Onboarding
  alias Cympho.Repo

  describe "Onboarding wizard" do
    test "walks the wizard and launches a company with owner, engineers, and runtime", %{
      conn: conn
    } do
      {view, html} = open_start_onboarding(conn)
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
      assert Onboarding.get_draft(live_assigns(view).current_user.id) == %{}

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

    test "restores safe draft fields and step after refresh without persisting credentials", %{
      conn: conn
    } do
      {view, _html} = open_start_onboarding(conn)
      user_id = live_assigns(view).current_user.id

      view |> element("button", "Continue") |> render_click()

      render_change(view, "update_company_form", %{
        "company" => %{
          "name" => "Resume This Company",
          "goal_title" => "Restore the safe owner goal",
          "project_name" => "Resumable Setup",
          "issue_prefix" => "RES",
          "adapter" => "codex",
          "runtime_model" => "gpt-safe-model",
          "runtime_command" => "export API_KEY=do-not-persist",
          "role_overrides" => true,
          "role_runtimes" => %{
            "cto" => %{
              "adapter" => "codex",
              "model" => "gpt-role-safe",
              "command" => "password=do-not-persist"
            }
          },
          "api_key" => "do-not-persist",
          "password" => "do-not-persist",
          "provider_token" => "do-not-persist"
        }
      })

      {:ok, refreshed, html} = live(conn, "/onboarding")
      refreshed_form = live_assigns(refreshed).company_form

      assert html =~ "Step 2 of 5"
      assert html =~ ~s(value="Resume This Company")
      assert refreshed_form["goal_title"] == "Restore the safe owner goal"
      assert refreshed_form["runtime_model"] == "gpt-safe-model"
      assert refreshed_form["runtime_command"] == ""
      assert get_in(refreshed_form, ["role_runtimes", "cto", "model"]) == "gpt-role-safe"
      assert get_in(refreshed_form, ["role_runtimes", "cto", "command"]) == ""

      persisted = Onboarding.get_draft(user_id) |> inspect()
      refute persisted =~ "API_KEY"
      refute persisted =~ "password="
      refute persisted =~ "api_key"
      refute persisted =~ "provider_token"
      refute persisted =~ "do-not-persist"
    end

    test "validation and runtime readiness errors keep safe draft fields across refresh", %{
      conn: conn
    } do
      {view, _html} = open_start_onboarding(conn)
      view |> element("button", "Continue") |> render_click()

      render_change(view, "update_company_form", %{
        "company" => %{
          "name" => "Keep Invalid Draft",
          "goal_title" => "Keep this goal",
          "project_name" => "Keep this project",
          "issue_prefix" => "bad",
          "adapter" => "claude_code",
          "runtime_model" => "gpt-5.5"
        }
      })

      html = view |> element("button", "Continue") |> render_click()
      assert html =~ "Issue prefix must be 2-7 uppercase letters."

      {:ok, refreshed, html} = live(conn, "/onboarding")
      assert html =~ "Step 2 of 5"
      assert html =~ ~s(value="Keep Invalid Draft")
      assert html =~ ~s(value="bad")

      render_change(refreshed, "update_company_form", %{
        "company" => %{"issue_prefix" => "KEEP"}
      })

      html = render_click(refreshed, "start_autonomous_company")
      assert html =~ "Claude Code"
      assert html =~ "gpt-5.5"

      {:ok, ready_retry, html} = live(conn, "/onboarding")
      assert html =~ "Step 3 of 5"
      assert live_assigns(ready_retry).company_form["runtime_model"] == "gpt-5.5"
      assert live_assigns(ready_retry).company_form["name"] == "Keep Invalid Draft"
    end

    test "improve adds goal and issue to the current company and clears the draft", %{
      current_company: _setup_company
    } do
      conn = CymphoWeb.LiveCase.authenticated_conn(%{role: "owner"})
      {:ok, view, choice_html} = live(conn, "/onboarding")
      current_company = live_assigns(view).current_company
      user = live_assigns(view).current_user
      company_count = Repo.aggregate(Company, :count, :id)

      assert choice_html =~ "Start a company"
      assert choice_html =~ "Improve this company"

      html =
        view
        |> element("button[phx-click='select_onboarding_path'][phx-value-path='improve']")
        |> render_click()

      assert html =~ "Improve #{current_company.name}"
      assert html =~ "No new company is created"

      view
      |> form("#improve-company-form",
        company: %{
          "goal_title" => "Improve customer activation",
          "improvement_details" => "Measure whether owners reach useful work in ten minutes."
        }
      )
      |> render_change()

      assert Onboarding.get_draft(user.id)["path"] == "improve"

      html = view |> element("button", "Create improvement") |> render_click()
      assert html =~ "Improvement ready"
      assert html =~ "No new company was created."
      assert Repo.aggregate(Company, :count, :id) == company_count
      assert Onboarding.get_draft(user.id) == %{}

      assert [goal] =
               current_company.id
               |> Goals.list_goals_by_company()
               |> Enum.filter(&(&1.title == "Improve customer activation"))

      assert [issue] =
               Issues.list_issues(%{company_id: current_company.id})
               |> Enum.filter(&(&1.title == "Improve customer activation"))

      assert issue.goal_id == goal.id
      assert issue.company_id == current_company.id

      render_click(view, "create_improvement")

      assert Enum.count(
               Goals.list_goals_by_company(current_company.id),
               &(&1.title == goal.title)
             ) ==
               1
    end

    test "per-role AI overrides land on the matching agents", %{conn: conn} do
      {view, _html} = open_start_onboarding(conn)

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
      {view, _html} = open_start_onboarding(conn)

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
      {view, _html} = open_start_onboarding(conn)

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
      {view, _html} = open_start_onboarding(conn)

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
      {view, _html} = open_start_onboarding(conn)

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
      {view, _html} = open_start_onboarding(conn)

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
      {view, _html} = open_start_onboarding(conn)

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
      {view, html} = open_start_onboarding(conn)

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

  defp open_start_onboarding(conn) do
    {:ok, view, choice_html} = live(conn, "/onboarding")
    assert choice_html =~ "Start a company"
    assert choice_html =~ "Improve this company"

    html =
      view
      |> element("button[phx-click='select_onboarding_path'][phx-value-path='start']")
      |> render_click()

    {view, html}
  end

  defp live_assigns(view) do
    :sys.get_state(view.pid).socket.assigns
  end
end
