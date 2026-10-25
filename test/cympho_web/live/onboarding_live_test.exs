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
      # r3: the template step is a Next step pair with paper option rows (build-spec §9 a);
      # the old blueprint card grid and its classes are gone.
      assert html =~ "Choose a company template"
      assert html =~ "Step 1 of 5"
      assert html =~ "data-ui-complex-page"

      document = Floki.parse_document!(html)

      assert [_radio | _] =
               Floki.find(document, "#blueprint-form input.opt-in[name='company[blueprint]']")

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
      # r3: the CEO/CTO description cards became the team's lead tiles (build-spec §9).
      assert html =~ "6 agents to start"
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

      # r3 (B9): Continue to review unlocks only after the readiness checks pass.
      pass_readiness(view)

      # team -> launch
      html = view |> element("button", "Continue") |> render_click()
      assert html =~ "Launch Wizard Co"
      assert html =~ "Ada"

      html = view |> element("button", "Launch Wizard Co") |> render_click()
      assert html =~ "all set"
      # r3: Ready leads into Home on its day-one state ("Enter Cympho" opened /issues).
      assert html =~ "Open Home"
      assert html =~ "/switch-company/"
      assert Onboarding.get_draft(live_assigns(view).current_user.id) == %{}

      company = Companies.get_company_by_slug("wizard-co")
      assert company

      # The signed-in LiveCase user must own the new company. list_memberships/1
      # preloads :user, so identity is assertable without a LiveCase helper.
      assert [membership] = Companies.list_memberships(company.id)
      assert membership.role == "owner"
      assert membership.is_board_member
      assert membership.user.email =~ "live-user-"

      # Onboarding default $100 → company cents + blocking Finances.BudgetPolicy.
      assert company.budget_monthly_cents == 10_000

      [budget_policy] =
        Cympho.Finances.list_budget_policies(company.id, is_active: true, scope: "company")

      assert budget_policy.action_on_exceed == "block"
      assert Decimal.eq?(budget_policy.budget_limit_usd, Decimal.new("100.00"))

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
      # r3: errors use the mockups' voice and sit under their field.
      assert html =~ "Use 2 to 7 capital letters for task IDs, like NW."

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

      # r3 (B9): launch needs a passing readiness check for the shared runtime.
      pass_readiness(view)
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
      # r3: the mockups' voice; the Advanced-only prefix field comes back into view.
      assert html =~ "Use 2 to 7 capital letters for task IDs, like NW."
      assert html =~ "Step 2 of 5"

      [prefix_field] = Floki.find(Floki.parse_document!(html), "#onboarding-issue-prefix")
      refute prefix_field |> Floki.attribute("class") |> Enum.join(" ") =~ "ui-advanced-only"
      assert has_element?(view, "#onboarding-issue-prefix[aria-invalid='true']")
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
      # r3: the mockups' voice, tied to the field by aria-describedby.
      assert html =~ "Enter a first goal."
      assert has_element?(view, "#ob-goal[aria-invalid='true'][aria-describedby='ob-goal-e']")
      assert html =~ "Step 2 of 5"
    end

    test "blocks the company step when monthly budget is zero", %{conn: conn} do
      {view, html} = open_start_onboarding(conn)
      # r3: glossary words ("company template", "spending limit").
      assert html =~ "Choose a company template"

      view |> element("button", "Continue") |> render_click()
      assert render(view) =~ "Spending limit per 30 days"

      view
      |> form("#company-step-form",
        company: %{
          "name" => "No Spend Cap Co",
          "goal_title" => "Must set a budget",
          "project_name" => "Ops",
          "issue_prefix" => "NSC",
          "budget_monthly_usd" => "0"
        }
      )
      |> render_change()

      html = view |> element("button", "Continue") |> render_click()
      assert html =~ "Enter a spending limit above $0."
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

      # r3 (B9): the launch reaches the transaction only after the checks pass.
      pass_readiness(view)
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

      # r3 (B9): the checks run on the sanitised adapter, as the launch does.
      pass_readiness(view)
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

      # r3: four templates first, "Show all 17" for the rest (build-spec §9 a); rows show
      # the short names ("Security compliance"), the full name was a tooltip.
      assert html =~ "4 of 17 templates"
      assert view |> element("button", "Show all 17") |> render_click() =~ "17 of 17 templates"

      html =
        view
        |> form("#blueprint-search-form", blueprint_query: "security")
        |> render_change()

      assert html =~ "Security compliance"
      assert html =~ "1 of 17"
      refute html =~ "Training academy"

      html =
        view
        |> form("#blueprint-search-form", blueprint_query: "training")
        |> render_change()

      assert html =~ "Training academy"
      assert html =~ "1 of 17"
      refute html =~ "Security compliance"
    end
  end

  describe "r3 onboarding: Team & AI (B8, B9, B10)" do
    test "the team step is one form: lead tiles, engineers, provider rows, readiness and the crew",
         %{conn: conn} do
      {view, html} = open_team_step(conn)
      doc = Floki.parse_document!(html)

      assert [_frame] = Floki.find(doc, "[data-page='onboarding'][data-ui-complex-page]")
      assert [_h1] = Floki.find(doc, "h1")
      assert Floki.text(Floki.find(doc, "h1")) =~ "Your team, and the AI it runs on"

      # One step is current in the step list; the two before it are done and go back.
      assert [current] = Floki.find(doc, "nav[aria-label='Setup steps'] [aria-current='step']")
      assert Floki.text(current) =~ "Team & AI"

      assert length(
               Floki.find(doc, "nav[aria-label='Setup steps'] button[phx-click='go_to_step']")
             ) == 2

      # The pair is one form: choices on paper, the crew and the page's one primary on ink.
      assert [_paper] = Floki.find(doc, "form#team-step-form.next > article.paper")
      assert [_ink] = Floki.find(doc, "form#team-step-form.next > article.ink")
      assert [_one] = Floki.find(doc, "main .pw, .ob .pw")

      # B8: suggested leader names, editable in the form.
      assert Floki.text(Floki.find(doc, ".lead")) =~ "Ada"
      assert Floki.text(Floki.find(doc, ".lead")) =~ "Theo"
      assert html =~ "Also on the team: Priya (Product Manager) and Jun (Designer)."
      assert [_] = Floki.find(doc, "input[name='company[leader_names][ceo]'][value='Ada']")
      crew = doc |> Floki.find(".crew .cn") |> Enum.map(&Floki.text/1) |> Enum.join(" | ")
      assert crew =~ "Ada" and crew =~ "Theo" and crew =~ "Priya" and crew =~ "Jun"
      assert length(Floki.find(doc, ".crew li")) == 6

      # Claude Code and Codex are the providers offered (Cursor/HTTP report no usage).
      providers = doc |> Floki.find("input[name='company[adapter]']") |> Floki.attribute("value")
      assert providers == ["claude_code", "codex"]

      # B9: nothing checked yet, so Continue to review is disabled.
      assert html =~ "Not checked yet"
      assert has_element?(view, "button.pw[disabled]", "Continue to review")
    end

    test "the rename disclosure stays open while names are typed (B8)", %{conn: conn} do
      {_view, html} = open_team_step(conn)

      # Each keystroke re-renders the form; without this the patch drops the
      # browser-set `open` attribute, closing the fields after one letter.
      [mounted] =
        html
        |> Floki.parse_document!()
        |> Floki.find("details.ob-ren")
        |> Floki.attribute("phx-mounted")

      assert Jason.decode!(mounted) == [["ignore_attrs", %{"attrs" => ["open"]}]]
    end

    test "no check runs on mount; Check runs it once and unlocks Continue", %{conn: conn} do
      {view, _html} = open_team_step(conn)
      user_id = live_assigns(view).current_user.id

      {:ok, view, html} = live(conn, "/onboarding")
      assert html =~ "Step 3 of 5"
      refute_received {:readiness_prober, _call, _args}

      view |> element("button", "Check") |> render_click()
      html = render_async(view)

      assert_received {:readiness_prober, :installed?, _program}
      assert_received {:readiness_prober, :answers?, "claude_code"}
      assert html =~ "Ready on this server"
      assert html =~ "a one-line test prompt was answered"
      assert html =~ "it reports the cost of every run"
      refute has_element?(view, "button.pw[disabled]")
      assert has_element?(view, "button.pw", "Continue to review")

      # Saved in the draft: a refresh shows the result and asks the server nothing.
      assert Onboarding.get_draft(user_id)["form"]["readiness"]["signed_in"] == true
      {:ok, _view, html} = live(conn, "/onboarding")
      assert html =~ "Ready on this server"
      refute_received {:readiness_prober, _call, _args}

      assert view |> element("button", "Continue to review") |> render_click() =~ "Step 4 of 5"
    end

    test "a refused test prompt keeps Continue locked, on the client and the server", %{
      conn: conn
    } do
      {view, _html} = open_team_step(conn)

      render_change(view, "update_company_form", %{
        "company" => %{"runtime_command" => "refused-claude"}
      })

      view |> element("button", "Check") |> render_click()
      html = render_async(view)

      assert html =~ "Not ready on this server"

      assert html =~
               "The test prompt was refused. Sign in to Claude Code on the server, then check again."

      assert has_element?(view, "button.pl", "Check again")
      assert has_element?(view, "a[href='/docs/ai-agents/cli-harnesses']", "How to fix this")
      assert has_element?(view, "button.pw[disabled]", "Continue to review")
      assert html =~ "Continue unlocks when every check passes."

      # A forged Continue or launch is refused too, and nothing is created.
      html = render_click(view, "next_step")
      assert html =~ "Step 3 of 5"
      assert html =~ "Every check must pass before you continue."

      render_click(view, "start_autonomous_company")
      assert Companies.get_company_by_slug("team-step-co") == nil
    end

    test "a result belongs to the runtime it was taken on", %{conn: conn} do
      {view, _html} = open_team_step(conn)
      pass_readiness(view)
      assert render(view) =~ "Ready on this server"

      html =
        render_change(view, "update_company_form", %{
          "company" => %{"runtime_model" => "claude-opus-4-8"}
        })

      assert html =~ "Not checked yet"
      assert has_element?(view, "button.pw[disabled]", "Continue to review")
    end

    test "renamed leaders launch under their names (B8)", %{conn: conn} do
      {view, _html} = open_team_step(conn)

      html =
        view
        |> form("#team-step-form",
          company: %{
            "leader_names" => %{"ceo" => "Grace", "cto" => ""},
            "engineer_names" => ["Ravi", "Mira"]
          }
        )
        |> render_change()

      assert Floki.text(Floki.find(Floki.parse_document!(html), ".crew")) =~ "Grace"

      pass_readiness(view)
      view |> element("button", "Continue to review") |> render_click()

      assert render(view) =~
               "Grace (CEO), CTO (CTO), Priya (Product Manager), Jun (Designer), Ravi and Mira (Engineers)"

      render_click(view, "start_autonomous_company")

      company = Companies.get_company_by_slug("team-step-co")
      names = company.id |> Companies.list_company_agents() |> Map.new(&{&1.role, &1.name})

      assert names[:ceo] == "Grace"
      assert names[:cto] == "CTO"
      assert names[:product_manager] == "Priya"
      assert names[:designer] == "Jun"
    end

    test "Codex needs both prices; they are written to every agent (B10)", %{conn: conn} do
      {view, _html} = open_team_step(conn)

      html =
        view
        |> form("#team-step-form",
          company: %{"adapter" => "codex", "runtime_model" => "gpt-5.4-mini"}
        )
        |> render_change()

      assert html =~ "These prices are saved on all 6 agents."
      assert html =~ "enter its input and output prices above"

      html =
        view
        |> form("#team-step-form", company: %{"price_input" => "0.75", "price_output" => ""})
        |> render_change()

      assert html =~ "Enter the output price. Without it the spending limit can&#39;t stop Codex."

      assert has_element?(
               view,
               "#ob-price_output[aria-invalid='true'][aria-describedby='ob-price-e']"
             )

      # Signed in and installed pass, but an unpriced Codex still cannot continue or launch.
      pass_readiness(view)
      assert has_element?(view, "button.pw[disabled]", "Continue to review")
      assert render_click(view, "next_step") =~ "Enter the output price."
      render_click(view, "start_autonomous_company")
      assert Companies.get_company_by_slug("team-step-co") == nil

      html =
        view
        |> form("#team-step-form", company: %{"price_output" => "4.50"})
        |> render_change()

      assert html =~ "you entered its prices"
      assert html =~ "Ready on this server"

      view |> element("button", "Continue to review") |> render_click()
      render_click(view, "start_autonomous_company")

      company = Companies.get_company_by_slug("team-step-co")
      agents = Companies.list_company_agents(company.id)
      assert length(agents) == 6

      for agent <- agents do
        assert agent.adapter == :codex
        assert agent.runtime_config["model"] == "gpt-5.4-mini"

        assert agent.runtime_config["pricing"] == %{
                 "gpt-5.4-mini" => %{
                   "input_usd_per_mtok" => "0.75",
                   "output_usd_per_mtok" => "4.50"
                 }
               }
      end
    end
  end

  describe "r3 onboarding: steps and defaults" do
    test "finished steps go back; a forged jump forward is ignored", %{conn: conn} do
      {view, _html} = open_team_step(conn)

      html =
        view |> element("button[phx-click='go_to_step'][phx-value-step='0']") |> render_click()

      assert html =~ "Step 1 of 5"

      html = render_click(view, "go_to_step", %{"step" => "3"})
      assert html =~ "Step 1 of 5"
    end

    test "the task-ID prefix and project follow the company name until set", %{conn: conn} do
      {view, _html} = open_start_onboarding(conn)
      view |> element("button", "Continue") |> render_click()

      render_change(view, "update_company_form", %{"company" => %{"name" => "Northwind Software"}})

      form = live_assigns(view).company_form
      assert form["issue_prefix"] == "NS"
      assert form["project_name"] == "Northwind Software app"

      render_change(view, "update_company_form", %{
        "company" => %{"name" => "Northwind Software", "issue_prefix" => "NW"}
      })

      render_change(view, "update_company_form", %{"company" => %{"name" => "Northwind Labs"}})
      form = live_assigns(view).company_form
      assert form["issue_prefix"] == "NW"
      assert form["project_name"] == "Northwind Labs app"

      # A name with no letters gives no prefix; the prefix is left as it was.
      render_change(view, "update_company_form", %{"company" => %{"name" => "2026"}})
      assert live_assigns(view).company_form["issue_prefix"] == "NW"
    end

    test "a readiness result cannot be sent in with the form", %{conn: conn} do
      {view, _html} = open_team_step(conn)

      render_change(view, "update_company_form", %{
        "company" => %{
          "readiness" => %{"checked" => "claude_code||", "installed" => true, "signed_in" => true}
        }
      })

      assert has_element?(view, "button.pw[disabled]", "Continue to review")
      assert render_click(view, "next_step") =~ "Every check must pass before you continue."
    end

    test "Review shows the team, the limit and the launch effect; Ready opens Home", %{conn: conn} do
      {view, _html} = open_team_step(conn)
      pass_readiness(view)

      html = view |> element("button", "Continue to review") |> render_click()
      assert html =~ "Team Step Co is ready to launch"
      assert html =~ "Claude Code · installed, signed in, priced"
      assert html =~ "per 30 days. Agents stop at the limit."
      assert html =~ "Cympho creates 6 agents and 5 first tasks."
      assert html =~ "TEAM-1 starts with Ada (CEO)."

      html = view |> element("button", "Launch Team Step Co") |> render_click()
      doc = Floki.parse_document!(html)
      assert Floki.text(Floki.find(doc, ".launch")) =~ "6 agents hired"
      assert Floki.text(Floki.find(doc, ".launch")) =~ "5 first tasks"
      # The dispatcher is off in tests (plan D1): the first task waits, and the card says why.
      assert html =~ "TEAM-1 waits for Ada (CEO)"
      assert html =~ "Agents are switched off on this server."

      company = Companies.get_company_by_slug("team-step-co")
      assert [href] = doc |> Floki.find("a.pw") |> Floki.attribute("href")
      assert href == "/switch-company/#{company.id}?return_to=/"
    end
  end

  # B9: the Fake prober (config/test.exs) passes any program not named "missing"/"refused".
  # Sent as the event, so it also works from steps that do not show the Check pill.
  defp pass_readiness(view) do
    render_click(view, "check_readiness")
    # The stubbed check runs in start_async; under a full parallel suite it can
    # take longer than render_async's 100 ms default.
    render_async(view, 1_000)
  end

  # Template and company filled in, then Continue twice: the team step (3 of 5).
  defp open_team_step(conn) do
    {view, _html} = open_start_onboarding(conn)
    view |> element("button", "Continue") |> render_click()

    render_change(view, "update_company_form", %{
      "company" => %{
        "name" => "Team Step Co",
        "goal_title" => "Ship the first release",
        "issue_prefix" => "TEAM",
        "budget_monthly_usd" => "300"
      }
    })

    html = view |> element("button", "Continue") |> render_click()
    assert html =~ "Step 3 of 5"
    {view, html}
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
