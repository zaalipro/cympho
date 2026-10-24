defmodule CymphoWeb.TeamRailLiveTest do
  use CymphoWeb.LiveCase, async: true

  alias Cympho.Agents
  alias Cympho.Approvals
  alias Cympho.Finances.BudgetPolicy
  alias Cympho.Finances.TokenUsage
  alias Cympho.Repo
  alias CymphoWeb.TeamRailLive

  defp session(conn, company_id) do
    %{
      "user_id" => Plug.Conn.get_session(conn, :user_id),
      "company_id" => company_id,
      "session_version" => 0
    }
  end

  defp agent!(company, name, status) do
    {:ok, agent} =
      Agents.create_agent(%{name: name, role: :engineer, status: status, company_id: company.id})

    agent
  end

  defp ask_for_approval!(agent) do
    {:ok, approval} =
      Approvals.create_approval(%{type: "launch_gate", requested_by_agent_id: agent.id})

    approval
  end

  defp rows(html) do
    html
    |> Floki.parse_fragment!()
    |> Floki.find(".roster li")
    |> Enum.map(fn li ->
      %{
        name: li |> Floki.find(".m-name") |> Floki.text(),
        word: li |> Floki.find(".m-word") |> Floki.text(),
        chip: li |> Floki.find(".fy") |> Floki.text(),
        pin: "pin" in (li |> Floki.attribute("class") |> List.first("") |> String.split())
      }
    end)
  end

  defp spend!(company, limit, spent) do
    %BudgetPolicy{}
    |> BudgetPolicy.changeset(%{
      company_id: company.id,
      scope: "company",
      period: "monthly",
      budget_limit_usd: Decimal.new(limit),
      warning_threshold_pct: Decimal.new("80.0")
    })
    |> Repo.insert!()

    Repo.insert!(%TokenUsage{
      company_id: company.id,
      provider: "test",
      model: "test",
      input_tokens: 100,
      output_tokens: 50,
      total_tokens: 150,
      cost_usd: Decimal.new(spent)
    })
  end

  setup %{conn: conn, current_company: company} do
    mira = agent!(company, "Mira", :paused)
    priya = agent!(company, "Priya", :idle)
    ravi = agent!(company, "Ravi", :idle)
    theo = agent!(company, "Theo", :running)
    _ada = agent!(company, "Ada", :idle)

    ask_for_approval!(mira)
    ask_for_approval!(priya)
    ask_for_approval!(ravi)
    ravi_second = ask_for_approval!(ravi)
    ask_for_approval!(theo)

    %{conn: conn, company: company, ravi_second: ravi_second}
  end

  test "orders the team: stopped first, then agents with items for you, then the rest", %{
    conn: conn,
    company: company
  } do
    {:ok, _view, html} = live_isolated(conn, TeamRailLive, session: session(conn, company.id))

    # r3: Mira was paused with nobody recorded as the pauser, so the merged
    # backend lists her as her own "Resume Mira" item (B2) beside her approval.
    assert rows(html) == [
             %{name: "Mira", word: "Paused", chip: "2 for you", pin: true},
             %{name: "Priya", word: "Idle", chip: "1 for you", pin: false},
             %{name: "Ravi", word: "Idle", chip: "2 for you", pin: false},
             %{name: "Theo", word: "Working", chip: "1 for you", pin: false},
             %{name: "Ada", word: "Idle", chip: "", pin: false}
           ]

    doc = Floki.parse_fragment!(html)
    assert [section] = Floki.find(doc, ~s(section.team[aria-label="Your team"]))
    assert [toggle] = Floki.find(section, "button.team-h")
    assert Floki.attribute(toggle, "aria-expanded") == ["true"]
    assert Floki.attribute(toggle, "aria-controls") == ["team-roster"]
    assert [_] = Floki.find(section, "ul#team-roster.roster")
    assert [see_all] = Floki.find(section, "a.see-all")
    assert Floki.attribute(see_all, "href") == ["/agents"]
  end

  test "the for-you chips add up to the Inbox count", %{conn: conn, company: company} do
    {:ok, _view, html} = live_isolated(conn, TeamRailLive, session: session(conn, company.id))

    chips =
      html
      |> rows()
      |> Enum.map(fn %{chip: chip} -> chip |> String.split(" ") |> hd() end)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&String.to_integer/1)
      |> Enum.sum()

    user = %{id: Plug.Conn.get_session(conn, :user_id)}
    assert chips == Cympho.OwnerAttention.unresolved_count(company.id, user)
  end

  test "never lists another company's agents", %{conn: conn, company: company} do
    {:ok, other} =
      Cympho.Companies.create_company(%{
        name: "Other Co",
        slug: "other-co-#{System.unique_integer([:positive])}"
      })

    agent!(other, "Outsider", :error)

    {:ok, _view, html} = live_isolated(conn, TeamRailLive, session: session(conn, company.id))
    refute html =~ "Outsider"
  end

  test "renders nothing for a session company the user does not belong to", %{conn: conn} do
    {:ok, other} =
      Cympho.Companies.create_company(%{
        name: "Not Mine",
        slug: "not-mine-#{System.unique_integer([:positive])}"
      })

    agent!(other, "Stranger", :error)

    {:ok, _view, html} = live_isolated(conn, TeamRailLive, session: session(conn, other.id))

    refute html =~ "Stranger"
  end

  test "renders nothing without a signed-in user" do
    conn = Phoenix.ConnTest.build_conn() |> Plug.Test.init_test_session(%{})

    {:ok, _view, html} = live_isolated(conn, TeamRailLive, session: %{})

    assert Floki.find(Floki.parse_fragment!(html), "section.team") == []
  end

  test "an owner-attention change refreshes the chips", %{
    conn: conn,
    company: company,
    ravi_second: approval
  } do
    {:ok, view, _html} = live_isolated(conn, TeamRailLive, session: session(conn, company.id))

    {:ok, _} =
      Approvals.resolve_approval(approval.id, :approved, %{
        resolution_reason: "Approved in test"
      })

    send(view.pid, {:owner_attention_changed, company.id})

    wait_until(fn ->
      ravi = view |> render() |> rows() |> Enum.find(&(&1.name == "Ravi"))
      assert ravi.chip == "1 for you"
    end)
  end

  describe "the spending slot" do
    test "stays out of the rail below the warning threshold", %{conn: conn, company: company} do
      spend!(company, "300", "186.50")

      {:ok, _view, html} = live_isolated(conn, TeamRailLive, session: session(conn, company.id))

      refute html =~ ~s(class="spend")
    end

    test "appears at 80% or more of the limit", %{conn: conn, company: company} do
      spend!(company, "300", "246")

      {:ok, _view, html} = live_isolated(conn, TeamRailLive, session: session(conn, company.id))
      doc = Floki.parse_fragment!(html)

      assert [slot] = Floki.find(doc, "a.spend")
      assert Floki.attribute(slot, "href") == ["/costs"]
      assert slot |> Floki.find(".spend-e") |> Floki.text() =~ "30 days"
      assert slot |> Floki.find(".spend-v") |> Floki.text() |> String.trim() == "$246 of $300"

      assert slot |> Floki.find(".spend-l") |> Floki.text() |> String.trim() ==
               "Agents stop at $300"

      assert Floki.find(slot, ".tk") != []
    end

    test "says Paused at the limit", %{conn: conn, company: company} do
      spend!(company, "300", "300")

      {:ok, _view, html} = live_isolated(conn, TeamRailLive, session: session(conn, company.id))
      doc = Floki.parse_fragment!(html)

      assert [slot] = Floki.find(doc, "a.spend")
      assert slot |> Floki.find(".spend-l.stop") |> Floki.text() =~ "limit reached"
      assert slot |> Floki.find(".spend-go") |> Floki.text() =~ "Open Spending"
    end
  end
end
