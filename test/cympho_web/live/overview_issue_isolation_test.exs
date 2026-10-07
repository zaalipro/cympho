defmodule CymphoWeb.OverviewIssueIsolationTest do
  use CymphoWeb.LiveCase, async: true

  import Plug.Conn, only: [get_session: 2]

  alias Cympho.{Agents, Comments, Companies, Issues, Repo}
  alias Cympho.HeartbeatEngine.Run
  alias CymphoWeb.Events

  test "overview company switches discard prior issue data and subscriptions", %{
    conn: conn,
    current_company: a
  } do
    user_id = Plug.Conn.get_session(conn, :user_id)
    unique = System.unique_integer([:positive])
    {:ok, b} = Companies.create_company(%{name: "Workflow B", slug: "workflow-b-#{unique}"})
    {:ok, c} = Companies.create_company(%{name: "HIDDEN_C", slug: "workflow-c-#{unique}"})
    {:ok, _} = Companies.create_membership(%{user_id: user_id, company_id: b.id, role: "member"})
    {a_issue, a_run} = running_issue(a, "A_ISSUE", user_id)
    {b_issue, b_run} = running_issue(b, "B_ISSUE", user_id)
    {c_issue, _} = running_issue(c, "C_ISSUE", user_id)

    {:ok, home, html} = live(conn, "/")
    assert html =~ "What should the team do?"
    assert html =~ ~s(href="/overview")
    # Sidebar navigation belongs to the static layout, outside LiveViewTest's DOM.
    GenServer.stop(home.pid)
    {:ok, overview, html} = live(conn, "/overview")
    assert html =~ b.name
    refute html =~ c.name

    b_link = "/switch-company/#{b.id}?return_to=%2Fissues"
    assert has_element?(overview, ~s(a[href="#{b_link}"]))
    GenServer.stop(overview.pid)
    b_conn = get(conn, b_link)
    assert get_session(b_conn, :company_id) == b.id
    assert redirected_to(b_conn) == "/issues"
    {:ok, b_tasks, html} = live(recycle(b_conn), "/issues")
    assert html =~ b_issue.title
    refute html =~ a_issue.title

    {:ok, b_view, html} =
      navigate(b_tasks, recycle(b_conn), "/issues/#{b_issue.id}", b_issue.title)

    assert html =~ "B_ISSUE_REVIEW"
    refute html =~ "A_ISSUE_REVIEW"
    Events.broadcast_run_progress(b_issue, b_run.id, %{bytes: 222, chunks: 2})
    assert render(element(b_view, "#issue-run-progress")) =~ "222 bytes"
    assert "company:#{b.id}:runs" in Registry.keys(Cympho.PubSub, b_view.pid)
    refute "company:#{a.id}:runs" in Registry.keys(Cympho.PubSub, b_view.pid)

    # Leaving issue Show must remove its company subscriptions, not just hide the panel.
    {:ok, b_tasks, _} = navigate(b_view, recycle(b_conn), "/issues", "Issues")
    wait_until(fn -> assert Registry.keys(Cympho.PubSub, b_view.pid) == [] end)
    GenServer.stop(b_tasks.pid)
    {:ok, overview, _} = live(recycle(b_conn), "/overview")
    a_link = "/switch-company/#{a.id}?return_to=%2Fissues"
    assert has_element?(overview, ~s(a[href="#{a_link}"]))
    GenServer.stop(overview.pid)
    a_conn = get(recycle(b_conn), a_link)
    assert get_session(a_conn, :company_id) == a.id
    {:ok, a_tasks, _} = live(recycle(a_conn), "/issues")

    {:ok, a_view, html} =
      navigate(a_tasks, recycle(a_conn), "/issues/#{a_issue.id}", a_issue.title)

    assert html =~ "A_ISSUE_REVIEW"
    refute html =~ "B_ISSUE_REVIEW"
    assert "company:#{a.id}:runs" in Registry.keys(Cympho.PubSub, a_view.pid)
    refute "company:#{b.id}:runs" in Registry.keys(Cympho.PubSub, a_view.pid)

    Events.broadcast_run_progress(a_issue, a_run.id, %{bytes: 111, chunks: 1})
    assert render(element(a_view, "#issue-run-progress")) =~ "111 bytes"
    Events.broadcast_run_progress(b_issue, b_run.id, %{bytes: 999, chunks: 9})

    {:ok, _} =
      Comments.create_comment(%{
        issue_id: b_issue.id,
        author_type: "user",
        author_id: user_id,
        body: "B_LATE_CONVERSATION_SENTINEL"
      })

    html = render(a_view)
    assert html =~ "111 bytes"
    refute html =~ "999 bytes"
    refute html =~ "B_LATE_CONVERSATION_SENTINEL"
    refute html =~ "B_ISSUE_REVIEW"
    refute html =~ "C_ISSUE"

    for {active_conn, company_id} <- [{recycle(b_conn), b.id}, {recycle(a_conn), a.id}] do
      forged = get(active_conn, "/switch-company/#{c.id}?return_to=%2Fissues%2F#{c_issue.id}")
      assert redirected_to(forged) == "/"
      assert get_session(forged, :company_id) == company_id

      assert {:error, {:live_redirect, %{to: "/issues"}}} =
               live(active_conn, "/issues/#{c_issue.id}")
    end
  end

  defp navigate(view, conn, path, text) do
    prefix = if path == "/issues", do: "", else: ".group.grid "

    view
    |> element(~s(#{prefix}a[data-phx-link="redirect"][href="#{path}"]), text)
    |> render_click()
    |> follow_redirect(conn, path)
  end

  defp running_issue(company, title, user_id) do
    {:ok, agent} =
      Agents.create_agent(%{company_id: company.id, name: "#{title} agent", role: :engineer})

    {:ok, issue} =
      Issues.create_issue(%{company_id: company.id, title: title, status: :in_progress})

    {:ok, _} =
      Comments.create_comment(%{
        issue_id: issue.id,
        author_type: "user",
        author_id: user_id,
        body: "[review] Verdict: changes requested.\nReason: #{title}_REVIEW"
      })

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    run =
      Repo.insert!(%Run{
        company_id: company.id,
        issue_id: issue.id,
        agent_id: agent.id,
        status: "running",
        adapter: "process",
        started_at: now
      })

    {issue, run}
  end
end
