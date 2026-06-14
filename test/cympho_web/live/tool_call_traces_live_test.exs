defmodule CymphoWeb.ToolCallTracesLiveTest do
  use CymphoWeb.LiveCase, async: true

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
    assert html =~ "Trace command"
    assert html =~ "No traces yet"
    assert html =~ "Launch runtime to capture tool evidence"
    assert html =~ "No tool evidence captured yet"
    assert html =~ "Launch runtime from Operations"
    assert html =~ ~s(href="/operations#runtime-launch-checklist")
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

    assert html =~ "Trace command"
    assert html =~ "Tool failures"
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
        actor_type: "system"
      })

    {:ok, view, _html} = live(conn, "/tool-call-traces")

    html =
      view
      |> element("tr[phx-value-id='#{trace.id}']")
      |> render_click()

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

    assert html =~ "Integrity unchecked"
    assert html =~ "Verify the audit chain"

    html =
      view
      |> element("button[phx-click='verify_integrity']", "Verify integrity")
      |> render_click()

    assert html =~ "Trace chain healthy"
    assert html =~ "Tool evidence is audit-ready"
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
