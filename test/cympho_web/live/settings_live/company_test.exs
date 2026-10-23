defmodule CymphoWeb.SettingsLive.CompanyTest do
  @moduledoc "r3 P8: Settings opens Company › Details with the alerts chooser (B6) as its Next step."
  use CymphoWeb.LiveCase, async: false

  alias Cympho.{Companies, Repo, Users}
  alias Cympho.Finances.{BudgetIncident, BudgetPolicy, TokenUsage}
  alias Cympho.Notifications.NotificationPreference
  alias Cympho.R3Fixtures

  setup do
    nw = R3Fixtures.northwind!()
    %{nw: nw, conn: session_conn(nw.user, nw.company)}
  end

  test "/settings opens Company › Details", %{conn: conn} do
    assert redirected_to(get(conn, "/settings")) == "/settings/company"
  end

  describe "the Next step: choose your alerts" do
    test "starts from what the dispatcher sends today", %{conn: conn, nw: nw} do
      {:ok, view, _html} = live(conn, "/settings/company")
      main = main_doc(view)

      assert text(main, "h1") == "Settings"
      assert text(main, ".next .paper .eyebrow") == "Next step · Setup"
      assert text(main, ".next .paper .nt") == "Choose your alerts"

      assert text(main, ".next .paper .obj") ==
               "Today Cympho only emails you when an approval is needed."

      assert coverage(main) == [
               {"Email", "On", [false, true, false, false, false]},
               {"Telegram", "Off", [false, false, false, false, false]},
               {"Webhook", "Off", [false, false, false, false, false]}
             ]

      assert text(main, ".pf-m") == "Email on · Telegram off · Webhook off"
      assert hrefs(Floki.find(main, ".next .paper .pf a")) == ["/settings/notifications"]

      [form] = Floki.find(main, ".next form.ink")
      assert Floki.attribute(form, "phx-submit") == ["choose_alerts"]
      assert Floki.attribute(form, "aria-label") == ["Choose your alerts"]

      assert texts(form, ".opt .ot") == [
               "An agent asks me something",
               "An approval is waiting",
               "Work is ready for my review",
               "Work stopped: a run failed or an agent was paused",
               "Spending reaches 80% or 100% of the limit"
             ]

      checked = form |> Floki.find("input[type=checkbox][checked]") |> Floki.attribute("value")
      assert checked == ["human_approval_required"]

      assert text(form, ".ink-note") ==
               "After you choose: Cympho emails #{nw.user.email} once per item you picked."

      assert length(Floki.find(main, ".pw")) == 1
      assert text(main, ".next .ink .pw") == "Choose alerts"
    end

    test "choosing saves exactly the checked events and the summary follows", %{
      conn: conn,
      nw: nw
    } do
      {:ok, view, _html} = live(conn, "/settings/company")

      view
      |> element(".next form.ink")
      |> render_submit(%{"events" => ["agent_question", "human_approval_required"]})

      assert_push_event(view, "toast", %{message: "Alerts saved.", type: "success"})

      email = Repo.get_by!(NotificationPreference, user_id: nw.user.id, channel_type: "email")

      assert email.config["events"] == %{
               "agent_question" => true,
               "human_approval_required" => true,
               "review_ready" => false,
               "work_stopped" => false,
               "spend_threshold" => false
             }

      main = main_doc(view)
      assert text(main, ".next .paper .eyebrow") == "All clear"
      assert text(main, ".next .paper .nt") == "Everything is set up"
      assert Floki.find(main, ".next .ink") == []
      assert {"Email", "On", [true, true, false, false, false]} = hd(coverage(main))
    end

    test "choosing nothing saves every event off", %{conn: conn, nw: nw} do
      {:ok, view, _html} = live(conn, "/settings/company")
      # No checkbox checked: the browser sends no "events" key at all.
      render_submit(view, "choose_alerts", %{})

      email = Repo.get_by!(NotificationPreference, user_id: nw.user.id, channel_type: "email")
      assert email.config["events"] |> Map.values() |> Enum.uniq() == [false]
    end

    test "choosing turns email on when it was off, so the promise holds", %{conn: conn, nw: nw} do
      Users.ensure_default_prefs(nw.user.id)
      {:ok, _} = Users.upsert_notification_pref(nw.user.id, "email", %{enabled: false})

      {:ok, view, _html} = live(conn, "/settings/company")
      view |> element(".next form.ink") |> render_submit(%{"events" => ["review_ready"]})

      assert Repo.get_by!(NotificationPreference, user_id: nw.user.id, channel_type: "email").enabled
    end

    test "a choice saved on the Alerts page counts as chosen", %{conn: conn, nw: nw} do
      prefs = Users.ensure_default_prefs(nw.user.id)
      email = Enum.find(prefs, &(&1.channel_type == "email"))
      # an older saved choice without the new keys, then one new event switched on
      {:ok, _} = Users.update_pref_events(email.id, %{"human_approval_required" => false})

      {:ok, _} =
        Users.update_pref_events(email.id, %{
          "human_approval_required" => false,
          "review_ready" => true
        })

      {:ok, view, _html} = live(conn, "/settings/company")
      assert text(main_doc(view), ".next .paper .nt") == "Everything is set up"
    end

    test "an older saved choice without the new events still asks", %{conn: conn, nw: nw} do
      prefs = Users.ensure_default_prefs(nw.user.id)
      email = Enum.find(prefs, &(&1.channel_type == "email"))
      {:ok, _} = Users.update_pref_events(email.id, %{"human_approval_required" => true})

      {:ok, view, _html} = live(conn, "/settings/company")
      assert text(main_doc(view), ".next .paper .nt") == "Choose your alerts"
    end

    test "a viewer sees where to choose instead of a form", %{nw: nw} do
      viewer = member!(nw.company, "viewer", false)
      {:ok, view, _html} = live(session_conn(viewer, nw.company), "/settings/company")
      main = main_doc(view)

      assert text(main, ".next .paper .nt") == "Choose your alerts"
      assert Floki.find(main, ".next form.ink") == []
      assert hrefs(Floki.find(main, ".next .ink a.pw")) == ["/settings/notifications"]
    end

    test "paused at the limit, the company-wide step comes first", %{conn: conn, nw: nw} do
      Repo.insert!(%TokenUsage{
        company_id: nw.company.id,
        provider: "claude_code",
        model: "test",
        total_tokens: 10,
        cost_usd: Decimal.new("120.00")
      })

      Repo.insert!(%BudgetIncident{
        company_id: nw.company.id,
        budget_policy_id: nw.budget_policy.id,
        event_type: "budget_exceeded",
        spend_usd: Decimal.new("306.50"),
        budget_limit_usd: Decimal.new("300"),
        threshold_pct: Decimal.new("102"),
        enforcement_status: "complete"
      })

      {:ok, view, _html} = live(conn, "/settings/company")
      assert text(main_doc(view), ".next .paper .nt") == "Raise the spending limit"
    end
  end

  describe "sections" do
    test "the section nav regroups every settings page", %{conn: conn, nw: nw} do
      {:ok, view, _html} = live(conn, "/settings/company")
      [nav] = view |> main_doc() |> Floki.find("nav.snav")

      assert Floki.attribute(nav, "aria-label") == ["Settings sections"]
      assert texts(nav, ".sn-g") == ["Company", "Connections", "You"]

      links =
        for a <- Floki.find(nav, "a"), do: {squish(Floki.text(a)), hd(Floki.attribute(a, "href"))}

      assert links == [
               {"Details", "/settings/company?section=details"},
               {"Members", "/settings/company?section=members"},
               {"Billing", "/settings/company?section=billing"},
               {"Review steps", "/settings/policies"},
               {"Audit log", "/settings/audit"},
               {"How agents run", "/settings/adapters"},
               {"Integrations", "/settings/integrations"},
               {"Keys and secrets", "/settings/secrets"},
               {"Network proxies", "/settings/proxies"},
               {"Plugins", "/plugins"},
               {"Profile", "/settings/profile"},
               {"Appearance", "/settings/appearance"},
               {"Alerts", "/settings/notifications"},
               {"Labels", "/labels"}
             ]

      assert texts(nav, "a[aria-current]") == ["Details"]
      assert texts(nav, "li.ui-advanced-only a") == ["Network proxies", "Plugins"]
    end

    test "Company details and Power read the company", %{conn: conn, nw: nw} do
      {:ok, view, _html} = live(conn, "/settings/company")
      main = main_doc(view)

      [details] = Floki.find(main, "section[aria-labelledby=cd-t]")
      assert texts(details, "dt") == ["Name", "Task ID prefix", "Goal", "Created"]

      assert texts(details, "dd") |> Enum.take(3) == [
               "Northwind Software",
               "NW",
               "Ship the Northwind invoicing app to its first 10 paying customers"
             ]

      assert hrefs(Floki.find(details, ".card-h a.pl")) == ["/companies/#{nw.company.id}/edit"]

      [power] = Floki.find(main, "section[aria-labelledby=po-t]")
      assert text(power, ".pw-st") == "Full power"

      actions = power |> Floki.find("form") |> Enum.flat_map(&Floki.attribute(&1, "action"))

      assert actions == [
               "/runtime-control/low-power",
               "/runtime-control/pause",
               "/runtime-control/stop"
             ]

      for form <- Floki.find(power, "form") do
        assert Floki.attribute(form, "method") == ["post"]
        assert Floki.find(form, "input[name=_csrf_token]") != []

        assert Floki.attribute(Floki.find(form, "input[name=return_to]"), "value") == [
                 "/settings/company"
               ]
      end

      assert power |> Floki.find("button") |> Enum.flat_map(&Floki.attribute(&1, "data-confirm")) ==
               [
                 "Switch to low power? Only urgent work keeps running.",
                 "Pause your agents? Queued work is saved for later.",
                 "Stop your agents and clear the queue?"
               ]
    end

    test "a member who cannot control runtime sees the power state without its buttons", %{nw: nw} do
      member = member!(nw.company, "member", false)
      {:ok, view, _html} = live(session_conn(member, nw.company), "/settings/company")
      [power] = view |> main_doc() |> Floki.find("section[aria-labelledby=po-t]")

      assert text(power, ".pw-st") == "Full power"
      assert Floki.find(power, "form") == []
      assert Floki.find(main_doc(view), "section[aria-labelledby=cd-t] .card-h a.pl") == []
    end

    test "another company's goal never shows", %{conn: conn} do
      other = R3Fixtures.northwind!()
      {:ok, _} = other.goal |> Ecto.Changeset.change(title: "Foreign goal") |> Repo.update()

      {:ok, view, _html} = live(conn, "/settings/company")
      refute Floki.text(main_doc(view)) =~ "Foreign goal"
    end

    test "Billing holds the limit and the runtime prices", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings/company?section=billing")
      main = main_doc(view)

      [nav] = Floki.find(main, "nav.snav")
      assert texts(nav, "a[aria-current]") == ["Billing"]

      [billing] = Floki.find(main, "section[aria-labelledby=bi-t]")

      assert text(billing, ".bill-l") ==
               "$300 per 30 days · warns at 80% · agents stop at the limit"

      assert hrefs(Floki.find(billing, ".bill a")) == ["/costs"]

      rows = for li <- Floki.find(billing, ".srow"), do: {text(li, ".rt"), text(li, ".rm")}

      assert {"Claude Code", "Reports its own cost · Ada, Jun, Priya, Ravi, Theo"} in rows
      assert {"Codex", "gpt-5.4-mini · $0.75 in · $4.50 out per 1M tokens · Mira"} in rows

      assert {"OpenAI-compatible chat", "gpt-5.4-mini · $0.75 in · $4.50 out per 1M tokens · Sol"} in rows

      assert text(billing, ".cfoot") ==
               "A runtime without prices can't run while a spending limit is on."
    end

    test "Members lists the people of this company and links where they are managed", %{
      conn: conn,
      nw: nw
    } do
      other = R3Fixtures.northwind!()
      {:ok, view, _html} = live(conn, "/settings/company?section=members")
      main = main_doc(view)

      assert texts(Floki.find(main, "nav.snav"), "a[aria-current]") == ["Members"]
      [members] = Floki.find(main, "section[aria-labelledby=me-t]")

      assert [{"Maya Chen", "Owner · " <> email}] =
               for(li <- Floki.find(members, ".srow"), do: {text(li, ".rt"), text(li, ".rm")})

      assert email == nw.user.email
      refute Floki.text(members) =~ other.user.email
      assert text(members, ".srow .end") =~ "Board member"
      assert hrefs(Floki.find(members, ".card-h a.pl")) == ["/companies/#{nw.company.id}"]
      assert text(members, ".cfoot") == "No pending invites."
    end

    test "on phones a section row opens that section as its own page", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings/company")
      assert view |> main_doc() |> Floki.find(".set.picked") == []

      {:ok, view, _html} = live(conn, "/settings/company?section=details")

      assert view
             |> main_doc()
             |> Floki.find(".set.picked .set-main section[aria-labelledby=cd-t]") != []
    end

    test "Billing without a limit says so", %{conn: conn} do
      Repo.update_all(BudgetPolicy, set: [is_active: false])
      {:ok, view, _html} = live(conn, "/settings/company?section=billing")
      [billing] = view |> main_doc() |> Floki.find("section[aria-labelledby=bi-t]")

      assert text(billing, ".bill-l") == "No spending limit is set."
      assert Floki.find(billing, ".cfoot") == []
    end
  end

  defp coverage(main) do
    for li <- Floki.find(main, ".cov li") do
      dots = for i <- Floki.find(li, ".cov-d i"), do: Floki.attribute(i, "class") == ["y"]
      {text(li, ".cov-c"), text(li, ".cov-s"), dots}
    end
  end

  defp main_doc(view), do: view |> render() |> Floki.parse_fragment!()
  defp text(node, selector), do: node |> Floki.find(selector) |> Floki.text() |> squish()

  defp texts(node, selector),
    do: node |> Floki.find(selector) |> Enum.map(&squish(Floki.text(&1)))

  defp squish(text), do: text |> String.replace(~r/\s+/u, " ") |> String.trim()
  defp hrefs(nodes), do: Enum.flat_map(nodes, &Floki.attribute(&1, "href"))

  defp session_conn(user, company) do
    Phoenix.ConnTest.build_conn()
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session("user_id", user.id)
    |> Plug.Conn.put_session("company_id", company.id)
  end

  defp member!(company, role, board?) do
    unique = System.unique_integer([:positive])

    {:ok, user} =
      Users.create_user(%{email: "settings-#{unique}@example.com", name: "Settings #{unique}"})

    {:ok, _} =
      Companies.create_membership(%{
        user_id: user.id,
        company_id: company.id,
        role: role,
        is_board_member: board?
      })

    user
  end
end
