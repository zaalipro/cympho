defmodule CymphoWeb.AuditTrailLiveTest do
  use CymphoWeb.LiveCase, async: true

  alias Cympho.Repo
  alias Cympho.AuditTrail.AuditEvent

  defp seed_events(company, count) do
    entries =
      for i <- 1..count do
        ts = ~U[2026-01-01 00:00:00Z] |> DateTime.add(i, :second) |> DateTime.truncate(:second)

        %{
          id: Ecto.UUID.generate(),
          company_id: company.id,
          event_type: "issue_created",
          actor_type: "system",
          actor_id: Ecto.UUID.generate(),
          resource_type: "issue",
          resource_id: Ecto.UUID.generate(),
          payload: %{"n" => "marker_#{String.pad_leading(Integer.to_string(i), 3, "0")}"},
          inserted_at: ts
        }
      end

    Repo.insert_all(AuditEvent, entries)
  end

  test "shows the empty state when there are no events", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/settings/audit")
    assert html =~ "No audit events found."
  end

  test "streams events and appends the next page", %{conn: conn, current_company: company} do
    seed_events(company, 51)

    {:ok, view, html} = live(conn, "/settings/audit")

    assert html =~ "marker_051"
    refute html =~ "marker_001"
    assert html =~ "audit-sentinel"

    view |> element("#audit-sentinel") |> render_hook("next-page")
    assert render(view) =~ "marker_001"
  end
end
