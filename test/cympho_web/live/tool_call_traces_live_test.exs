defmodule CymphoWeb.ToolCallTracesLiveTest do
  use CymphoWeb.LiveCase, async: true

  import CymphoWeb.R3PageHelpers

  alias Cympho.Repo
  alias Cympho.Issues
  alias Cympho.ToolCallTraces
  alias Cympho.ToolCallTraces.ToolCallTrace

  defp seed_traces(company, count, attrs \\ %{}) do
    entries =
      for i <- 1..count do
        n = String.pad_leading(Integer.to_string(i), 3, "0")
        ts = ~U[2026-01-01 00:00:00Z] |> DateTime.add(i, :second) |> DateTime.truncate(:second)

        Map.merge(
          %{
            id: Ecto.UUID.generate(),
            company_id: company.id,
            trace_type: "tool_call",
            tool_name: "marker_#{n}",
            tool_arguments: %{},
            status: "success",
            content_hash: String.pad_leading(Integer.to_string(i), 64, "0"),
            chain_hash: String.duplicate("b", 64),
            sequence_number: i,
            occurred_at: ts,
            actor_type: "system",
            inserted_at: ts,
            updated_at: ts
          },
          attrs
        )
      end

    Repo.insert_all(ToolCallTrace, entries)
  end

  test "shows the empty state when there are no traces", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/tool-call-traces")
    doc = main_doc(html)

    # r3 (v7 O2): a root page under Team; its one header control checks the chain.
    assert_r3_page(doc, page: "steps", h1: "Step log", kind: :root, primaries: 0)
    assert texts(doc, ".ctx-end button[phx-click='verify_integrity']") == ["Check the chain"]

    # The trace command is a band: its heading, and the chain's state as a word.
    assert text(doc, "#trace-command .h2") == "Audit chain"
    assert text(doc, "#trace-command .card-h .st-w") == "Integrity not checked"
    assert html =~ "Launch runtime to capture tool evidence"

    # The empty table keeps its in-stream row, with a quiet line inside.
    assert text(doc, "#traces-tbody #traces-empty .gl-big") == "No tool evidence captured yet"
    assert html =~ "Launch runtime from Health"
    assert html =~ ~s(href="/operations#runtime-launch-checklist")
  end

  test "the filters sit behind one Filter chip and exports in the Steps header", %{
    conn: conn,
    current_company: company
  } do
    seed_traces(company, 2)
    {:ok, view, html} = live(conn, "/tool-call-traces")
    doc = main_doc(html)

    for name <- ~w(tool_name status agent_id issue_id run_id) do
      assert Floki.find(doc, ~s(details#trace-filter form#trace-filters [name="filter[#{name}]"])) !=
               [],
             "filter[#{name}] is not in the Filter panel"
    end

    assert has_element?(
             view,
             "section#traces-table button.pl[phx-click='export_json']",
             "Export JSON"
           )

    assert has_element?(
             view,
             "section#traces-table button.pl[phx-click='export_csv']",
             "Export CSV"
           )

    # Once generated, each export is a native download anchor in its place.
    html = view |> element("button[phx-click='export_json']") |> render_click()
    doc = main_doc(html)
    [href] = Floki.attribute(doc, "section#traces-table a.pl[download]", "href")
    assert String.starts_with?(href, "data:application/json")
    refute has_element?(view, "button[phx-click='export_json']")

    # A set filter is counted on the chip.
    html =
      view
      |> form("#trace-filters", %{"filter" => %{"tool_name" => "marker_001"}})
      |> render_change()

    assert text(main_doc(html), "#trace-filter summary .mono") == "1"
  end

  test "filtered empty state explains how to recover", %{conn: conn, current_company: company} do
    seed_traces(company, 1, %{tool_name: "bash"})

    {:ok, view, _html} = live(conn, "/tool-call-traces")

    html =
      view
      |> form("#trace-filters", %{
        "filter" => %{
          "tool_name" => "missing_tool",
          "status" => "",
          "agent_id" => "",
          "issue_id" => ""
        }
      })
      |> render_submit()

    assert html =~ "No traces match these filters"
    assert html =~ "Clear filters to return to the full trace chain"
    assert html =~ "Clear filters"
    assert html =~ ~s(href="/operations#runtime-launch-checklist")
  end

  test "summarizes failed traces as the next debug action", %{
    conn: conn,
    current_company: company
  } do
    seed_traces(company, 1, %{status: "error", tool_name: "bash"})

    {:ok, _view, html} = live(conn, "/tool-call-traces")

    assert html =~ "Audit chain"
    assert html =~ "Inspect failed tool calls"
    assert html =~ "1 tool call ended in error"
    assert html =~ ~s(href="#trace-filters")
  end

  test "selected failed trace exposes issue recovery and focused relaunch", %{
    conn: conn,
    current_company: company
  } do
    {:ok, issue} =
      Issues.create_issue(
        scoped_attrs(%{
          title: "Recover failed tool trace",
          description: "Trace should point back to this issue.",
          status: :todo,
          priority: :high
        })
      )

    {:ok, trace} =
      ToolCallTraces.create_tool_call_trace(%{
        company_id: company.id,
        issue_id: issue.id,
        trace_type: "tool_call",
        tool_name: "shell",
        tool_arguments: %{"cmd" => "mix test"},
        error_message: "command failed",
        status: "error",
        actor_type: "system",
        occurred_at: ~U[2025-03-04 05:06:07Z]
      })

    {:ok, view, _html} = live(conn, "/tool-call-traces")

    # Each row's sequence number is a real button (keyboard), as well as the row click.
    assert has_element?(
             view,
             "#traces-tbody button.ul[phx-click='select_trace'][phx-value-id='#{trace.id}']"
           )

    assert text(main_doc(view), "#traces-tbody tr[phx-value-id='#{trace.id}'] .st-w") == "Failed"

    html =
      view
      |> element("tr[phx-value-id='#{trace.id}']")
      |> render_click()

    doc = main_doc(html)
    # The selected row is marked, and its details open in an aside band beside the table.
    assert Floki.attribute(doc, "tr[phx-value-id='#{trace.id}']", "aria-current") == ["true"]
    assert text(doc, "#trace-det-t") == "Step details"

    # An audit record keeps its full moment: year, seconds and the zone, machine-readable too.
    assert text(doc, ".st-det time") == "Tue 4 Mar 2025 05:06:07 UTC"
    assert Floki.attribute(doc, ".st-det time", "datetime") == ["2025-03-04T05:06:07Z"]
    assert html =~ "Failure recovery"
    assert html =~ "The shell call failed"
    assert html =~ ~s(href="/issues/#{issue.id}")
    assert html =~ "Open runtime failures"
    assert html =~ "Focused relaunch"
    assert html =~ "Copy command"
    assert html =~ "CYMPHO_DISPATCH_ONLY_ISSUE_ID=#{issue.id}"
    assert html =~ "mise exec -- mix phx.server"
  end

  test "verify integrity updates command to healthy when chain is intact", %{
    conn: conn,
    current_company: company
  } do
    {:ok, _trace} =
      ToolCallTraces.create_tool_call_trace(%{
        company_id: company.id,
        trace_type: "tool_call",
        tool_name: "read_file",
        tool_arguments: %{"path" => "README.md"},
        tool_result: "ok",
        status: "success",
        actor_type: "system"
      })

    {:ok, view, html} = live(conn, "/tool-call-traces")

    assert html =~ "Integrity not checked"
    assert html =~ "Verify the audit chain"

    html =
      view
      |> element("button[phx-click='verify_integrity']", "Check the chain")
      |> render_click()

    assert text(main_doc(html), "#trace-command .card-h .st-w") == "Chain integrity verified"
    assert html =~ "Tool evidence is audit-ready"
  end

  test "verify integrity flags stale content hashes", %{
    conn: conn,
    current_company: company
  } do
    {:ok, trace} =
      ToolCallTraces.create_tool_call_trace(%{
        company_id: company.id,
        trace_type: "tool_call",
        tool_name: "read_file",
        tool_arguments: %{"path" => "README.md"},
        tool_result: "ok",
        status: "success",
        actor_type: "system"
      })

    trace
    |> Ecto.Changeset.change(%{tool_name: "tampered_tool"})
    |> Repo.update!()

    {:ok, view, _html} = live(conn, "/tool-call-traces")

    html =
      view
      |> element("button[phx-click='verify_integrity']", "Check the chain")
      |> render_click()

    assert html =~ "Content hash mismatch at sequence 1"
    assert html =~ "content modified since last review"
  end

  test "streams the traces table and appends the next page", %{
    conn: conn,
    current_company: company
  } do
    seed_traces(company, 51)

    {:ok, view, html} = live(conn, "/tool-call-traces")

    assert html =~ "marker_051"
    refute html =~ "marker_001"
    assert html =~ "traces-sentinel"

    view |> element("#traces-sentinel") |> render_hook("next-page")
    assert render(view) =~ "marker_001"
  end
end
