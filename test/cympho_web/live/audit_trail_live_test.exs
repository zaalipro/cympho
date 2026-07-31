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

  defp insert_event(company, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    attrs =
      %{
        company_id: company.id,
        event_type: "issue_created",
        actor_type: "system",
        actor_id: Ecto.UUID.generate(),
        resource_type: "issue",
        resource_id: Ecto.UUID.generate(),
        payload: %{},
        inserted_at: now
      }
      |> Map.merge(attrs)

    Repo.insert!(struct(AuditEvent, attrs))
  end

  test "shows the empty state when there are no events", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/settings/audit")
    assert html =~ ~s(data-testid="audit-command")
    # The page used to say "no events" twice with different wording; the feed
    # slot now carries only the way out.
    assert html =~ "No audit events have been recorded yet"
    refute html =~ "No audit events found."
    assert html =~ "Clear filters or create governable work to populate the audit trail."
  end

  test "audit command prioritizes reversed governance decisions", %{
    conn: conn,
    current_company: company
  } do
    insert_event(company, %{event_type: "issue_created"})

    insert_event(company, %{
      event_type: "orchestrator_session_started",
      resource_type: "orchestrator_session"
    })

    reversed =
      insert_event(company, %{
        event_type: "decision_reversed",
        actor_type: "user",
        resource_type: "decision",
        payload: %{"reason" => "wrong path"}
      })

    {:ok, _view, html} = live(conn, "/settings/audit")

    assert html =~ ~s(data-testid="audit-command")
    assert html =~ "Review reversed governance decisions"
    assert html =~ "Open reviews"
    assert html =~ "Governance"
    assert html =~ "Runtime"
    assert html =~ "Decision reversed"
    assert html =~ ~s(data-testid="audit-payload-#{reversed.id}")
    assert html =~ "Decision reversed payload - 1 key: reason"
  end

  test "filtered empty command links back to the full audit trail", %{
    conn: conn,
    current_company: company
  } do
    insert_event(company, %{event_type: "issue_created", actor_type: "system"})

    {:ok, _view, html} = live(conn, "/settings/audit?filter_actor_type=user")

    assert html =~ "No audit events match this view"
    assert html =~ "Clear filters"
    assert html =~ ~s(href="/settings/audit")
  end

  test "company runtime controls render as runtime audit evidence", %{
    conn: conn,
    current_company: company
  } do
    stopped =
      insert_event(company, %{
        event_type: "company_runtime_stopped",
        actor_type: "user",
        resource_type: "company",
        resource_id: company.id,
        payload: %{
          "issues_released" => 2,
          "runs_cancelled" => 3,
          "wakes_cancelled" => 4
        }
      })

    {:ok, _view, html} = live(conn, "/settings/audit")

    assert html =~ "Inspect runtime audit evidence"
    assert html =~ "Runtime"
    assert html =~ "Company runtime stopped"
    assert html =~ ~s(data-testid="audit-payload-#{stopped.id}")
    assert html =~ "Company runtime stopped payload"
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
