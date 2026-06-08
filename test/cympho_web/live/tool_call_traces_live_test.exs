defmodule CymphoWeb.ToolCallTracesLiveTest do
  use CymphoWeb.LiveCase, async: true

  alias Cympho.Repo
  alias Cympho.ToolCallTraces.ToolCallTrace

  defp seed_traces(company, count) do
    entries =
      for i <- 1..count do
        n = String.pad_leading(Integer.to_string(i), 3, "0")
        ts = ~U[2026-01-01 00:00:00Z] |> DateTime.add(i, :second) |> DateTime.truncate(:second)

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
        }
      end

    Repo.insert_all(ToolCallTrace, entries)
  end

  test "shows the empty state when there are no traces", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/tool-call-traces")
    assert html =~ "No traces found"
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
