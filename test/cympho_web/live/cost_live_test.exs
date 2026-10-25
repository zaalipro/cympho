defmodule CymphoWeb.CostLiveTest do
  use CymphoWeb.LiveCase, async: true

  alias Cympho.Budgets.Budget
  alias Cympho.Finances.{BudgetPolicy, TokenUsage}
  alias Cympho.R3Fixtures
  alias Cympho.Repo

  describe "cost analytics" do
    test "renders one actionable empty state when no spend exists", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/costs")

      # Nine breakdown cards each saying "no X yet" collapse into a single
      # panel; the per-card empty states only appear when part of the data
      # landed.
      assert html =~ ~s(data-testid="cost-breakdowns-empty")
      assert html =~ "No spend recorded in this window"
      assert html =~ "Set a spending limit before launching more runtime"
      assert html =~ ~s(href="/budgets/new")
      assert html =~ ~s(href="/operations#runtime-launch-checklist")

      refute html =~ ~s(data-testid="daily-cost-empty")
      refute html =~ ~s(data-testid="cost-agent-empty")
      refute html =~ ~s(data-testid="cost-provider-empty")
      assert html =~ ~s(data-testid="active-budgets-empty")
    end

    test "prompts for a company budget when spend is unbudgeted", %{
      conn: conn,
      current_company: company
    } do
      insert_token_usage(company, cost_usd: Decimal.new("12.50"), provider: "dashscope")

      {:ok, _view, html} = live(conn, "/costs")

      # r3: the limit block replaces the cost command card; with no limit its
      # Next step sends the owner to set one.
      assert html =~ "Set a spending limit"
      assert html =~ "Nothing stops agents from spending more."
      assert html =~ "$12.50"
      assert html =~ ~s(href="/budgets/new")
      assert html =~ "Spend runway"
      assert html =~ "No company runway"
      assert html =~ "Set a comparable budget"
      assert html =~ "N/A"
    end

    test "surfaces spend watch with the top provider driver", %{
      conn: conn,
      current_company: company
    } do
      insert_budget_policy(company, budget_limit_usd: Decimal.new("100.00"))
      insert_token_usage(company, cost_usd: Decimal.new("85.00"), provider: "dashscope")

      {:ok, _view, html} = live(conn, "/costs")

      # r3: the warning is the limit block's Next step; the provider is in Advanced's By runtime.
      assert html =~ "Decide on the spending limit"
      assert html =~ "in the last 30 days. Agents stop at $100."
      assert html =~ "Dashscope"
      assert html =~ "Spend runway"
      assert html =~ "Short runway"
      assert html =~ "5.3 days"
      assert html =~ "$2.8333"
      assert html =~ "$15.00"
    end

    test "surfaces unpriced token usage instead of implying zero spend is clean", %{
      conn: conn,
      current_company: company
    } do
      insert_token_usage(company,
        cost_usd: Decimal.new("0.00"),
        provider: "codex",
        model: "gpt-5.4-mini",
        input_tokens: 1_000_000,
        output_tokens: 500_000
      )

      {:ok, _view, html} = live(conn, "/costs")

      # r3: one "Usage we couldn't price" card replaces the cost command badge and the warning box.
      assert html =~ ~s(data-testid="unpriced-usage-warning")
      assert html =~ "Usage we couldn&#39;t price"
      assert html =~ "1.5M tokens across 1 request reported no price"
      assert html =~ "not in the totals above"
      assert html =~ "$0"
    end

    test "renders active budget utilization without noisy decimal precision", %{
      conn: conn,
      current_company: company
    } do
      insert_runtime_budget(company,
        name: "Monthly runtime cap",
        limit_amount: Decimal.new("100.00"),
        spent_amount: Decimal.new("0.00")
      )

      insert_token_usage(company, cost_usd: Decimal.new("25.50"))

      {:ok, _view, html} = live(conn, "/costs")

      assert html =~ "Monthly runtime cap"
      assert html =~ "25.5%"
      refute html =~ "25.500%"
    end

    test "active budget bars use TokenUsage spend not static spent_amount", %{
      conn: conn,
      current_company: company
    } do
      insert_runtime_budget(company,
        name: "Provider spend cap",
        limit_amount: Decimal.new("100.00"),
        spent_amount: Decimal.new("0.00")
      )

      insert_token_usage(company, cost_usd: Decimal.new("33.25"))

      {:ok, _view, html} = live(conn, "/costs")

      assert html =~ "Provider spend cap"
      assert html =~ "$33.25 of $100.00"
      assert html =~ "33.3%"
      # Static spent_amount stayed 0 — must not render as the Used figure.
      refute html =~ "$0.00 of $100.00"
    end

    test "approaching alert uses live TokenUsage threshold not spent_amount", %{
      conn: conn,
      current_company: company
    } do
      insert_runtime_budget(company,
        name: "Near limit cap",
        limit_amount: Decimal.new("100.00"),
        spent_amount: Decimal.new("0.00"),
        threshold_alert_percentage: 80
      )

      insert_token_usage(company, cost_usd: Decimal.new("85.00"))

      {:ok, _view, html} = live(conn, "/costs")

      assert html =~ "Approaching Budget Limits"
      assert html =~ "Near limit cap"
      assert html =~ "85%"
    end

    test "exceeded alert fires from live spend when status is still active", %{
      conn: conn,
      current_company: company
    } do
      insert_runtime_budget(company,
        name: "Hard stop cap",
        limit_amount: Decimal.new("50.00"),
        spent_amount: Decimal.new("0.00"),
        status: "active"
      )

      insert_token_usage(company, cost_usd: Decimal.new("55.00"))

      {:ok, _view, html} = live(conn, "/costs")

      assert html =~ "Exceeded Budgets"
      assert html =~ "Hard stop cap"
      assert html =~ "110%"
    end
  end

  describe "r3 Spending" do
    setup do
      nw = R3Fixtures.northwind!()
      %{nw: nw, conn: session_conn(nw.user, nw.company)}
    end

    test "the Next step is the limit block with the change form", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/costs")
      main = main_doc(view)

      assert text(main, "h1") == "Spending"
      assert text(main, ".h1-aside") =~ "since "
      assert text(main, ".next .paper .eyebrow") == "All clear · Limit"
      # The dot is decoration, hidden from screen readers, as in every r3 eyebrow.
      assert texts(main, ".next .paper .eyebrow > span[aria-hidden=true]") == ["·"]
      assert text(main, ".next .paper .nt") == "Spending is within your limit"
      assert text(main, ".next .hero .mono") == "$186.50"
      assert text(main, ".next .hero .u") == "of $300 · last 30 days"

      assert texts(main, ".strip.s3 .v") == [
               "62%",
               "$113.50",
               text(main, ".strip.s3 .cell:last-child .v")
             ]

      assert texts(main, ".strip.s3 .l") == [
               "of the limit",
               "left before agents stop",
               "set at setup"
             ]

      assert text(main, ".tk-legend .w") == "warns $240"

      [form] = Floki.find(main, ".next form.ink")
      assert Floki.attribute(form, "aria-label") == ["Change the spending limit"]
      assert Floki.attribute(form, "phx-submit") == ["change_limit"]
      assert Floki.attribute(Floki.find(form, "input[name=limit]"), "value") == ["300"]

      assert text(main, ".next .ink .ink-note") ==
               "After you change it: agents stop at the new amount instead of $300."

      assert length(Floki.find(main, ".pw")) == 1
      assert text(main, ".next .ink .pw") == "Change limit"
    end

    test "By agent lists every agent's 30-day and 24-hour spend", %{conn: conn, nw: nw} do
      {:ok, view, _html} = live(conn, "/costs")
      [card] = view |> main_doc() |> Floki.find("section[aria-labelledby=ba-t]")

      assert text(card, ".card-h .meta") == "Last 24 hours $14.82"

      rows =
        for tr <- Floki.find(card, "tbody tr") do
          [name, d30, d1] = tr |> Floki.find("th, td") |> Enum.map(&squish(Floki.text(&1)))
          {String.slice(name, 2..-1//1), d30, d1}
        end

      assert rows == [
               {"Ravi", "$52.80", "$5.12"},
               {"Theo", "$41.60", "$3.44"},
               {"Ada", "$38.20", "$1.06"},
               {"Mira", "$19.40", "$3.68"},
               {"Priya", "$14.90", "$0.61"},
               {"Jun", "$12.35", "$0.47"},
               {"Sol", "$7.25", "$0.44"}
             ]

      assert hd(hrefs(Floki.find(card, "a.nm"))) == "/agents/#{nw.agents["Ravi"].id}?from=/costs"
    end

    test "By task: the top six, the rest, and what is not tied to a task add up", %{
      conn: conn,
      nw: nw
    } do
      {:ok, view, _html} = live(conn, "/costs")
      [card] = view |> main_doc() |> Floki.find("section[aria-labelledby=bt-t]")

      [first | _] = Floki.find(card, "table.money")
      top = for tr <- Floki.find(first, "tbody tr"), do: row_cells(tr)

      assert top == [
               {"NW-2", "$41.30"},
               {"NW-1", "$24.60"},
               {"NW-3", "$22.75"},
               {"NW-10", "$19.40"},
               {"NW-9", "$9.80"},
               {"NW-4", "$9.40"}
             ]

      # r3: NW-5 has no spend, so it is not a row (the mockup lists it at $0.00).
      assert text(card, "details.more > summary") == "4 more · $22.05"
      more = for tr <- Floki.find(card, "details.more tbody tr"), do: row_cells(tr)
      assert Enum.map(more, &elem(&1, 0)) == ~w(NW-8 NW-6 NW-7 NW-11)
      assert text(card, ".untied .amt") == "$37.20"

      # accounting: every dollar of the 30-day total is in exactly one row
      sum =
        (top ++ more)
        |> Enum.map(&elem(&1, 1))
        |> Kernel.++([text(card, ".untied .amt")])
        |> Enum.map(&Decimal.new(String.trim_leading(&1, "$")))
        |> Enum.reduce(Decimal.new(0), &Decimal.add/2)

      assert Decimal.equal?(sum, Decimal.new("186.50"))

      hrefs = hrefs(Floki.find(card, "a.nm"))
      assert "/issues/#{nw.issues["NW-2"].id}?from=/costs" in hrefs
      refute Enum.any?(hrefs, &String.starts_with?(&1, "/workspace"))
    end

    test "Advanced By runtime names each runtime's agents", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/costs")
      [card] = view |> main_doc() |> Floki.find("section[aria-labelledby=rt-t]")

      assert text(card, "h2 .adv") == "Adv"

      rows =
        for li <- Floki.find(card, ".rtl li"),
            do:
              {li |> Floki.find("span") |> Enum.at(1) |> Floki.text() |> squish(),
               text(li, ".mono")}

      assert rows == [
               {"Claude Code Ada, Jun, Priya, Ravi, Theo", "$159.85"},
               {"Codex Mira", "$19.40"},
               {"OpenAI-compatible chat Sol", "$7.25"}
             ]
    end

    test "another company's spend never shows", %{conn: conn} do
      other = R3Fixtures.northwind!()
      {:ok, _} = Cympho.Agents.update_agent(other.agents["Ravi"], %{name: "Zed"})

      {:ok, view, _html} = live(conn, "/costs")
      main = main_doc(view)

      refute Floki.text(main) =~ "Zed"
      assert text(main, ".next .hero .mono") == "$186.50"
    end

    test "a board member changes the limit", %{conn: conn, nw: nw} do
      {:ok, view, _html} = live(conn, "/costs")

      view |> element(".next form.ink") |> render_submit(%{"limit" => "400"})

      assert_push_event(view, "toast", %{message: "Limit changed to $400.", type: "success"})
      assert Decimal.equal?(Repo.get!(BudgetPolicy, nw.budget_policy.id).budget_limit_usd, 400)
      assert text(main_doc(view), ".next .hero .u") == "of $400 · last 30 days"
    end

    test "an invalid amount is flagged on the field, not in a toast, and the limit stays", %{
      conn: conn,
      nw: nw
    } do
      {:ok, view, _html} = live(conn, "/costs")

      for bad <- ["abc", "-1", "0"] do
        view |> element(".next form.ink") |> render_submit(%{"limit" => bad})

        refute_push_event(view, "toast", %{type: "error"})
        main = main_doc(view)
        [input] = Floki.find(main, ".next form.ink input[name=limit]")
        assert Floki.attribute(input, "value") == [bad]
        assert Floki.attribute(input, "aria-invalid") == ["true"]
        assert Floki.attribute(input, "aria-describedby") == ["lim-h lim-e"]
        assert text(main, ".next form.ink p.err#lim-e") == "Enter an amount above $0."
      end

      assert Decimal.equal?(Repo.get!(BudgetPolicy, nw.budget_policy.id).budget_limit_usd, 300)

      # A good amount clears the flag.
      view |> element(".next form.ink") |> render_submit(%{"limit" => "400"})
      main = main_doc(view)
      [input] = Floki.find(main, ".next form.ink input[name=limit]")
      assert Floki.attribute(input, "aria-invalid") == []
      assert Floki.attribute(input, "aria-describedby") == ["lim-h"]
      assert Floki.find(main, "#lim-e") == []
    end

    test "amounts read with thousands separators; the field keeps plain digits", %{
      conn: conn,
      nw: nw
    } do
      {:ok, view, _html} = live(conn, "/costs")

      view |> element(".next form.ink") |> render_submit(%{"limit" => "1000"})

      assert_push_event(view, "toast", %{message: "Limit changed to $1,000.", type: "success"})
      main = main_doc(view)
      assert text(main, ".next .hero .u") == "of $1,000 · last 30 days"
      assert Floki.attribute(Floki.find(main, "input[name=limit]"), "value") == ["1000"]

      view |> element(".next form.ink") |> render_submit(%{"limit" => "1234.5"})

      assert_push_event(view, "toast", %{message: "Limit changed to $1,234.50.", type: "success"})
      main = main_doc(view)
      assert text(main, ".next .hero .u") == "of $1,234.50 · last 30 days"
      assert Floki.attribute(Floki.find(main, "input[name=limit]"), "value") == ["1234.50"]

      assert Decimal.equal?(
               Repo.get!(BudgetPolicy, nw.budget_policy.id).budget_limit_usd,
               "1234.50"
             )
    end

    test "a member who is not on the board sees the form disabled and cannot submit", %{nw: nw} do
      user = extra_member!(nw.company, "admin", false)
      {:ok, view, _html} = live(session_conn(user, nw.company), "/costs")
      main = main_doc(view)

      assert Floki.find(main, ".next form.ink input[name=limit][disabled]") != []
      assert Floki.find(main, ".next form.ink button.pw[disabled]") != []
      assert text(main, ".next form.ink .ink-help") =~ "Only board members can change the limit."

      render_submit(view, "change_limit", %{"limit" => "900"})
      assert_push_event(view, "toast", %{message: "Only board members can change the limit."})
      assert Decimal.equal?(Repo.get!(BudgetPolicy, nw.budget_policy.id).budget_limit_usd, 300)
    end

    test "a viewer on the board is refused by the company role check", %{nw: nw} do
      user = extra_member!(nw.company, "viewer", true)
      {:ok, view, _html} = live(session_conn(user, nw.company), "/costs")

      render_submit(view, "change_limit", %{"limit" => "900"})

      assert Decimal.equal?(Repo.get!(BudgetPolicy, nw.budget_policy.id).budget_limit_usd, 300)
    end

    test "at 80% the Next step asks to decide on the limit", %{nw: nw} do
      company = spend_company!(nw.user, "246.00", "active")
      {:ok, view, _html} = live(session_conn(nw.user, company), "/costs")
      main = main_doc(view)

      assert text(main, ".next .paper .eyebrow") == "Next step · Limit warning"
      assert text(main, ".next .paper .nt") == "Decide on the spending limit"

      assert text(main, ".next .paper .obj") ==
               "$246 of $300 in the last 30 days. Agents stop at $300."

      assert Floki.find(main, ".next .paper .tk.lr") != []
    end

    test "paused at the limit: raise it, then resume agents", %{nw: nw} do
      company = spend_company!(nw.user, "300.00", "paused")
      {:ok, view, _html} = live(session_conn(nw.user, company), "/costs")
      main = main_doc(view)

      assert text(main, ".next .paper .eyebrow") == "Next step · Limit reached"
      assert text(main, ".next .paper .nt") == "Raise the limit to restart agents"

      assert text(main, ".next .paper .obj") ==
               "Agents stopped: the $300 limit for the last 30 days was reached."

      assert texts(main, ".next .ink .conseq li") == [
               "After you change it: agents stop at the new amount instead of $300.",
               "After you resume: agents start picking up work again."
             ]

      [resume] = Floki.find(main, ".next .ink button.pd")
      assert squish(Floki.text(resume)) == "Resume agents"
      [form_id] = Floki.attribute(resume, "form")
      [resume_form] = Floki.find(main, "form##{form_id}")
      assert Floki.attribute(resume_form, "action") == ["/runtime-control/resume"]
      assert Floki.attribute(resume_form, "method") == ["post"]
      assert Floki.find(resume_form, "input[name=_csrf_token]") != []

      assert Floki.attribute(Floki.find(resume_form, "input[name=return_to]"), "value") == [
               "/costs"
             ]

      assert length(Floki.find(main, ".pw")) == 1
    end

    test "without a limit the Next step opens Spending limit", %{conn: conn, nw: nw} do
      Repo.update_all(BudgetPolicy, set: [is_active: false])
      {:ok, view, _html} = live(conn, "/costs")
      main = main_doc(view)

      assert text(main, ".next .paper .nt") == "Set a spending limit"
      assert hrefs(Floki.find(main, ".next .ink a.pw")) == ["/budgets/new"]
      assert Floki.find(main, "input[name=limit]") == []
      _ = nw
    end

    test "with several company-wide limits the change happens on Spending limit", %{
      conn: conn,
      nw: nw
    } do
      insert_budget_policy(nw.company, budget_limit_usd: Decimal.new("500.00"))
      {:ok, view, _html} = live(conn, "/costs")
      main = main_doc(view)

      assert Floki.find(main, "input[name=limit]") == []
      assert hrefs(Floki.find(main, ".next .ink a.pw")) == ["/budgets"]
    end
  end

  defp main_doc(view), do: view |> render() |> Floki.parse_fragment!()
  defp text(node, selector), do: node |> Floki.find(selector) |> Floki.text() |> squish()

  defp texts(node, selector),
    do: node |> Floki.find(selector) |> Enum.map(&squish(Floki.text(&1)))

  defp squish(text), do: text |> String.replace(~r/\s+/u, " ") |> String.trim()
  defp hrefs(nodes), do: Enum.flat_map(nodes, &Floki.attribute(&1, "href"))

  defp row_cells(tr) do
    {text(tr, ".id"), tr |> Floki.find(".amt > span:last-child") |> Floki.text() |> squish()}
  end

  defp session_conn(user, company) do
    Phoenix.ConnTest.build_conn()
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session("user_id", user.id)
    |> Plug.Conn.put_session("company_id", company.id)
  end

  defp extra_member!(company, role, board?) do
    unique = System.unique_integer([:positive])

    {:ok, user} =
      Cympho.Users.create_user(%{email: "spend-#{unique}@example.com", name: "Spend #{unique}"})

    {:ok, _} =
      Cympho.Companies.create_membership(%{
        user_id: user.id,
        company_id: company.id,
        role: role,
        is_board_member: board?
      })

    user
  end

  # A company the user owns whose 30-day spend is `spent` of a $300 block limit.
  defp spend_company!(user, spent, status) do
    unique = System.unique_integer([:positive])

    {:ok, company} =
      Cympho.Companies.create_company(%{name: "Spend #{unique}", slug: "spend-#{unique}"})

    {:ok, company} = Cympho.Companies.execute_company_update(company, %{status: status})

    {:ok, _} =
      Cympho.Companies.create_membership(%{
        user_id: user.id,
        company_id: company.id,
        role: "owner",
        is_board_member: true
      })

    policy =
      Repo.insert!(%BudgetPolicy{
        company_id: company.id,
        scope: "company",
        period: "monthly",
        budget_limit_usd: Decimal.new("300.00"),
        warning_threshold_pct: Decimal.new("80.0"),
        action_on_exceed: "block",
        is_active: true
      })

    insert_token_usage(company, cost_usd: Decimal.new(spent), provider: "claude_code")

    if status == "paused" do
      Repo.insert!(%Cympho.Finances.BudgetIncident{
        company_id: company.id,
        budget_policy_id: policy.id,
        event_type: "budget_exceeded",
        spend_usd: Decimal.new(spent),
        budget_limit_usd: Decimal.new("300.00"),
        threshold_pct: Decimal.new("100"),
        enforcement_status: "complete"
      })
    end

    company
  end

  defp insert_token_usage(company, attrs) do
    attrs =
      [
        company_id: company.id,
        provider: "test",
        model: "qwen3.7-plus",
        input_tokens: 100,
        output_tokens: 50
      ]
      |> Keyword.merge(attrs)
      |> Map.new()

    %TokenUsage{}
    |> TokenUsage.changeset(attrs)
    |> Repo.insert!()
  end

  defp insert_budget_policy(company, attrs) do
    attrs =
      attrs
      |> Keyword.merge(
        company_id: company.id,
        scope: "company",
        period: "monthly",
        warning_threshold_pct: Decimal.new("80.0"),
        action_on_exceed: "warn",
        is_active: true
      )
      |> Map.new()

    %BudgetPolicy{}
    |> BudgetPolicy.changeset(attrs)
    |> Repo.insert!()
  end

  defp insert_runtime_budget(company, attrs) do
    attrs =
      [
        company_id: company.id,
        scope_type: "company",
        scope_id: company.id,
        currency: "USD",
        threshold_alert_percentage: 80,
        hard_stop: true,
        status: "active"
      ]
      |> Keyword.merge(attrs)
      |> Map.new()

    %Budget{}
    |> Budget.changeset(attrs)
    |> Repo.insert!()
  end
end
