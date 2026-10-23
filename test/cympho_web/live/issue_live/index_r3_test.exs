defmodule CymphoWeb.IssueLive.IndexR3Test do
  @moduledoc "The r3 Tasks list (plan P5): groups in the owner's order and Assign and retry."
  use CymphoWeb.LiveCase, async: true

  import Phoenix.LiveViewTest

  alias Cympho.Agents.Agent
  alias Cympho.Companies
  alias Cympho.Issues
  alias Cympho.R3Fixtures
  alias Cympho.Repo

  setup do
    nw = R3Fixtures.northwind!()
    %{nw: nw, conn: session_conn(nw.user, nw.company)}
  end

  describe "the grouped list" do
    test "every task sits in one group, in the owner's order", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/issues")
      main = main_doc(view)

      assert [{"div", _, _}] = Floki.find(main, "div.frame[data-page='tasks']")
      assert text(main, "h1") == "Tasks"

      groups =
        main
        |> Floki.find("section.grp, details.grp")
        |> Enum.map(fn group ->
          {text(group, ".gh"), Enum.map(Floki.find(group, ".tid"), &squish(Floki.text(&1)))}
        end)

      assert groups == [
               {"Blocked 1", []},
               {"Waiting on you 3", ["NW-6", "NW-7", "NW-4"]},
               {"Working 1", ["NW-9"]},
               {"To do 1", ["NW-5"]},
               {"Done in the last 7 days 4", ["NW-8", "NW-3", "NW-2", "NW-1"]},
               {"Cancelled 1", ["NW-11"]}
             ]

      # Done and Cancelled start closed; Later is hidden when empty.
      assert Floki.find(main, "details.grp[open]") == []
      refute text(main, ".grp") =~ "Later"
    end

    test "rows read the owner-facing state and carry a verb only when the owner acts", %{
      conn: conn,
      nw: nw
    } do
      {:ok, view, _html} = live(conn, "/issues")
      rows = Floki.find(main_doc(view), "li.tr")
      row = fn id -> Enum.find(rows, &(text(&1, ".tid") == id)) end

      assert text(row.("NW-6"), ".rm") =~ "Ravi asked you"
      assert text(row.("NW-6"), "a.go") == "Answer"

      assert hrefs(Floki.find(row.("NW-6"), "a.go")) == [
               "/issues/#{nw.issues["NW-6"].id}?from=/issues"
             ]

      assert text(row.("NW-6"), ".prio") == "High"
      assert text(row.("NW-7"), ".prio") == ""
      assert text(row.("NW-4"), ".rm") =~ "Ready for your review · Ravi"
      assert text(row.("NW-4"), "a.go") == "Review"
      assert text(row.("NW-9"), ".rm") =~ "Theo reviewing Jun's work"
      assert Floki.find(row.("NW-9"), "a.go") == []
      assert text(row.("NW-5"), ".rm") =~ "Ada · starts after NW-4 is accepted"
      assert text(row.("NW-11"), "s") == "Native mobile app spike"
    end

    test "NW-10 opens as the Next step: decide who retries it", %{conn: conn, nw: nw} do
      {:ok, view, _html} = live(conn, "/issues")
      main = main_doc(view)
      [blocked] = Floki.find(main, "section.grp[aria-labelledby='tg-blocked']")

      assert text(blocked, ".next .paper .nt") == "Decide who retries NW-10"
      assert text(blocked, ".next .paper .obj") =~ "nobody is assigned now (was Mira)"
      assert length(Floki.find(blocked, ".next figure.rb .rb-bar")) == 3

      [form] = Floki.find(blocked, ".next form.ink")
      assert Floki.attribute(form, "phx-submit") == ["assign_and_retry"]

      options =
        Enum.map(Floki.find(form, ".opt-w"), fn opt ->
          input = Floki.find(opt, "input")

          {text(opt, ".ot-n"), Floki.attribute(input, "checked") != [],
           Floki.attribute(input, "disabled") != []}
        end)

      assert options == [{"Ravi", true, false}, {"Theo", false, false}, {"Mira", false, true}]
      assert [primary] = Floki.find(main, ".pw")
      assert text(primary, "*") =~ "Assign and retry"

      assert Floki.attribute(Floki.find(form, "input[name='issue_id']"), "value") == [
               nw.issues["NW-10"].id
             ]
    end

    test "search finds a task by ID or title; a match the owner acts on opens", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/issues?search=nw-1")
      main = main_doc(view)

      assert text(main, ".next .paper .nt") == "Decide who retries NW-10"
      assert main |> Floki.find(".tid") |> Enum.map(&squish(Floki.text(&1))) == ["NW-1", "NW-11"]

      {:ok, view, _html} = live(conn, "/issues?search=Pricing")
      main = main_doc(view)

      assert text(main, ".next .paper .nt") == "Answer Priya's question"
      assert main |> Floki.find(".tid") |> Enum.map(&squish(Floki.text(&1))) == ["NW-8"]
    end
  end

  describe "Assign and retry" do
    test "assigns the chosen agent, reopens the task and queues it", %{conn: conn, nw: nw} do
      {:ok, view, _html} = live(conn, "/issues")

      view
      |> form("form[phx-submit='assign_and_retry']", %{"agent_id" => nw.agents["Ravi"].id})
      |> render_submit()

      issue = Issues.get_issue!(nw.issues["NW-10"].id)
      assert issue.assignee_id == nw.agents["Ravi"].id
      assert issue.status == :todo
      assert get_in(issue.monitor_state, ["dispatch", "pinned_at"])
      assert_push_event(view, "toast", %{message: "NW-10 goes to Ravi."})

      [todo] = Floki.find(main_doc(view), "section.grp[aria-labelledby='tg-todo']")
      assert "NW-10" in Enum.map(Floki.find(todo, ".tid"), &squish(Floki.text(&1)))
    end

    test "refuses a paused agent", %{conn: conn, nw: nw} do
      {:ok, view, _html} = live(conn, "/issues")

      render_submit(view, "assign_and_retry", %{
        "issue_id" => nw.issues["NW-10"].id,
        "agent_id" => nw.agents["Mira"].id
      })

      assert_unchanged(nw)
      assert_push_event(view, "toast", %{type: "error"})
    end

    test "refuses another company's agent and another company's task", %{conn: conn, nw: nw} do
      other = R3Fixtures.northwind!()
      {:ok, view, _html} = live(conn, "/issues")

      render_submit(view, "assign_and_retry", %{
        "issue_id" => nw.issues["NW-10"].id,
        "agent_id" => other.agents["Ravi"].id
      })

      assert_unchanged(nw)

      render_submit(view, "assign_and_retry", %{
        "issue_id" => other.issues["NW-10"].id,
        "agent_id" => nw.agents["Ravi"].id
      })

      assert_unchanged(other)
    end

    test "a viewer cannot assign", %{nw: nw} do
      unique = System.unique_integer([:positive])

      {:ok, viewer} =
        Cympho.Users.create_user(%{email: "tasks-viewer-#{unique}@example.com", name: "Viewer"})

      {:ok, _} =
        Companies.create_membership(%{
          user_id: viewer.id,
          company_id: nw.company.id,
          role: "viewer"
        })

      {:ok, view, _html} = live(session_conn(viewer, nw.company), "/issues")

      render_submit(view, "assign_and_retry", %{
        "issue_id" => nw.issues["NW-10"].id,
        "agent_id" => nw.agents["Ravi"].id
      })

      assert_unchanged(nw)
    end
  end

  describe "the Board" do
    test "columns by status, owner-needed cards lifted, a question parks its task", %{
      conn: conn,
      nw: nw
    } do
      {:ok, view, _html} = live(conn, "/kanban")
      main = main_doc(view)

      assert text(main, "h1") == "Tasks"

      columns =
        main
        |> Floki.find(".bcol")
        |> Enum.map(fn col ->
          {text(col, "h2.gh"),
           Enum.map(Floki.find(col, "[data-kanban-card]"), &text(&1, ".bc-top .mono"))}
        end)

      assert columns == [
               {"To do 1", ["NW-5"]},
               {"Working 0", []},
               {"In review 2", ["NW-4", "NW-9"]},
               {"Blocked 3", ["NW-10", "NW-6", "NW-7"]},
               {"Done 4", ["NW-8", "NW-3", "NW-2", "NW-1"]}
             ]

      card = fn id ->
        Enum.find(Floki.find(main, "[data-kanban-card]"), &(text(&1, ".bc-top .mono") == id))
      end

      lifted? = fn id ->
        card.(id) |> Floki.attribute("class") |> hd() |> String.contains?("quiet") |> Kernel.not()
      end

      assert Enum.filter(~w(NW-4 NW-5 NW-6 NW-7 NW-9 NW-10 NW-8), lifted?) ==
               ~w(NW-4 NW-6 NW-7 NW-10)

      assert text(card.("NW-10"), ".bchip") == "Unassigned · was Mira"
      assert text(card.("NW-6"), ".bchip") == "Waiting on you"
      assert text(card.("NW-4"), ".bchip") == "Your review"
      assert text(card.("NW-9"), ".bchip") == "Theo reviewing"
      assert text(card.("NW-5"), ".bchip") == "After NW-4"
      assert text(card.("NW-6"), ".bc-who") =~ "Ravi"

      assert hrefs(Floki.find(card.("NW-6"), "a.bc-t")) ==
               ["/issues/#{nw.issues["NW-6"].id}?from=/kanban"]

      assert main |> Floki.find("button.colp") |> Enum.map(&squish(Floki.text(&1))) ==
               ["Later 0", "Cancelled 1"]
    end
  end

  describe "List and Board" do
    test "the view switch carries the filters both ways", %{conn: conn, nw: nw} do
      {:ok, view, _html} = live(conn, "/issues?priority=high&search=nw")

      board =
        view
        |> main_doc()
        |> Floki.find("[data-testid='task-view-switch'] a[aria-label='Board view']")
        |> hrefs()

      assert board == ["/kanban?priority=high&search=nw"]

      {:ok, view, _html} = live(conn, "/kanban?priority=high&search=nw")
      main = main_doc(view)

      assert main
             |> Floki.find("[data-testid='task-view-switch'] a[aria-label='List view']")
             |> hrefs() == ["/issues?priority=high&search=nw"]

      cards =
        main
        |> Floki.find("[data-kanban-card]")
        |> Enum.flat_map(&Floki.attribute(&1, "data-issue-id"))

      assert nw.issues["NW-6"].id in cards
      refute nw.issues["NW-7"].id in cards
    end
  end

  defp assert_unchanged(nw) do
    issue = Issues.get_issue!(nw.issues["NW-10"].id)
    assert issue.assignee_id == nil
    assert issue.status == :blocked
    assert Repo.get!(Agent, nw.agents["Mira"].id).status == :paused
  end

  defp session_conn(user, company) do
    Phoenix.ConnTest.build_conn()
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session("user_id", user.id)
    |> Plug.Conn.put_session("company_id", company.id)
  end

  defp main_doc(view), do: view |> render() |> Floki.parse_fragment!()

  defp text(node, selector), do: node |> Floki.find(selector) |> Floki.text() |> squish()

  defp squish(text), do: text |> String.replace(~r/\s+/u, " ") |> String.trim()

  defp hrefs(nodes), do: Enum.flat_map(nodes, &Floki.attribute(&1, "href"))
end
