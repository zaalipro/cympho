defmodule CymphoWeb.ActivityLiveTest do
  use CymphoWeb.LiveCase, async: true

  import CymphoWeb.R3PageHelpers

  alias Cympho.Repo
  alias Cympho.Activities.Activity

  # Replace the auto-logged "created" activity with `count` markers whose
  # inserted_at is strictly increasing, so page boundaries are predictable.
  defp seed_markers(company, issue, count) do
    Repo.delete_all(Activity)

    entries =
      for i <- 1..count do
        n = String.pad_leading(Integer.to_string(i), 3, "0")

        %{
          id: Ecto.UUID.generate(),
          issue_id: issue.id,
          company_id: company.id,
          actor_type: "system",
          action: "marker_#{n}",
          metadata: %{},
          inserted_at:
            ~U[2026-01-01 00:00:00Z] |> DateTime.add(i, :second) |> DateTime.truncate(:second)
        }
      end

    Repo.insert_all(Activity, entries)
  end

  defp insert_activity(issue, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    attrs =
      %{
        issue_id: issue.id,
        company_id: issue.company_id,
        actor_type: "system",
        actor_id: nil,
        action: "created",
        metadata: %{},
        inserted_at: now
      }
      |> Map.merge(attrs)

    Repo.insert!(struct(Activity, attrs))
  end

  test "shows the empty state when there are no activities", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/activity")
    doc = main_doc(html)
    # r3 (v7 G4): a root page under Home; the filters sit behind one Filter chip.
    assert_r3_page(doc, page: "activity", h1: "Activity", kind: :root, primaries: 0)
    assert Floki.find(doc, ~s(details#activity-filter select[name="filter_action"])) != []
    assert Floki.find(doc, ~s(details#activity-filter select[name="filter_actor_type"])) != []
    assert Floki.find(doc, ~s(section#activity-feed #activity-list.rows)) != []
    assert html =~ ~s(data-testid="activity-command")
    assert html =~ "No company activity has been captured yet"
    assert html =~ "Audit lanes"
    assert html =~ "Issue changes"
    assert html =~ "Governance decisions"
    assert html =~ "Spend events"
    assert html =~ "Runtime events"
    assert html =~ "No activity found."
  end

  test "activity command prioritizes budget threshold activity", %{
    conn: conn,
    current_company: company
  } do
    {:ok, issue} = Cympho.Issues.create_issue(%{title: "Spend spike", company_id: company.id})

    Repo.delete_all(Activity)

    insert_activity(issue, %{action: "created"})

    insert_activity(issue, %{
      actor_type: "user",
      actor_id: Ecto.UUID.generate(),
      action: "approval_created",
      metadata: %{"user_name" => "Nina Owner"}
    })

    insert_activity(issue, %{action: "heartbeat_failed"})

    insert_activity(issue, %{
      action: "budget_threshold_exceeded",
      metadata: %{"threshold_type" => "issue"}
    })

    {:ok, _view, html} = live(conn, "/activity")

    assert html =~ ~s(data-testid="activity-command")
    assert html =~ "Review budget threshold activity before the next run"
    assert html =~ "Open costs"
    assert html =~ "Budget threshold exceeded"
    assert html =~ "Nina Owner"
    # The six-number metric strip is gone; the audit lane cards are the only
    # place the per-family counts render now.
    assert html =~ ~s(data-testid="activity-audit-lanes")
    assert html =~ "Audit lanes"
    assert html =~ "Issue changes"
    assert html =~ "Governance decisions"
    assert html =~ "Spend events"
    assert html =~ "Runtime events"
    assert html =~ "Other events"
    assert html =~ "Show budget threshold exceeded"
    assert html =~ ~s(href="/activity?filter_action=budget_threshold_exceeded")
    assert html =~ "Show approval created"
    assert html =~ ~s(href="/activity?filter_action=approval_created")
  end

  # r3 ground-r1 IMP-1: rows store only the actor id, so the feed printed
  # "User f25863fb" for the owner's own actions.
  test "names user and agent actors from the company, not their id", %{
    conn: conn,
    current_company: company
  } do
    unique = System.unique_integer([:positive])
    {:ok, issue} = Cympho.Issues.create_issue(%{title: "Named actors", company_id: company.id})

    {:ok, member} =
      Cympho.Users.create_user(%{
        email: "maya-#{unique}@example.com",
        name: "Maya Chen",
        password: "password1234"
      })

    {:ok, _} =
      Cympho.Companies.create_membership(%{
        user_id: member.id,
        company_id: company.id,
        role: "owner"
      })

    {:ok, outsider} =
      Cympho.Users.create_user(%{
        email: "outsider-#{unique}@example.com",
        name: "Olga Outsider",
        password: "password1234"
      })

    {:ok, agent} =
      Cympho.Agents.create_agent(%{
        company_id: company.id,
        name: "Ravi",
        role: :engineer,
        status: :idle,
        adapter: :claude_code
      })

    Repo.delete_all(Activity)

    by_member =
      insert_activity(issue, %{actor_type: "user", actor_id: member.id, action: "status_changed"})

    by_agent =
      insert_activity(issue, %{actor_type: "agent", actor_id: agent.id, action: "assigned"})

    by_outsider =
      insert_activity(issue, %{actor_type: "user", actor_id: outsider.id, action: "title_changed"})

    {:ok, view, html} = live(conn, "/activity")
    row = fn activity -> view |> element("#activities-#{activity.id}") |> render() end

    # Each event is a row: the sentence, then who · task · when.
    doc = main_doc(html)
    assert text(doc, "#activities-#{by_member.id} .rt") =~ "Status changed"
    assert text(doc, "#activities-#{by_member.id} .rm") =~ "Maya Chen · Named actors"

    assert Floki.attribute(doc, "#activities-#{by_member.id} .rm a.ul", "href") == [
             "/issues/#{issue.id}"
           ]

    assert row.(by_member) =~ "Maya Chen"
    refute html =~ "User #{String.slice(member.id, 0, 8)}"
    assert row.(by_agent) =~ "Ravi"
    refute html =~ "Agent #{String.slice(agent.id, 0, 8)}"
    # Only the company's own members are named.
    refute html =~ "Olga Outsider"
    assert row.(by_outsider) =~ "User #{String.slice(outsider.id, 0, 8)}"
  end

  test "each row reads as a sentence from the event's own detail", %{
    conn: conn,
    current_company: company
  } do
    {:ok, issue} = Cympho.Issues.create_issue(%{title: "Sentence probe", company_id: company.id})
    Repo.delete_all(Activity)

    status =
      insert_activity(issue, %{
        action: "status_changed",
        metadata: %{"from" => "todo", "to" => "in_progress"}
      })

    cost = insert_activity(issue, %{action: "cost_incurred", metadata: %{"amount" => "1.25"}})

    # A nested value is not a sentence part: the row keeps the action's label.
    nested =
      insert_activity(issue, %{action: "status_changed", metadata: %{"to" => %{"x" => 1}}})

    failed = insert_activity(issue, %{action: "heartbeat_failed"})

    {:ok, _view, html} = live(conn, "/activity")
    doc = main_doc(html)

    assert text(doc, "#activities-#{status.id} .rt") == "Status changed from todo to in progress"
    assert text(doc, "#activities-#{cost.id} .rt") == "Cost incurred: 1.25"
    assert text(doc, "#activities-#{nested.id} .rt") == "Status changed"
    # A failure is a problem row.
    assert Floki.find(doc, "#activities-#{failed.id} .kt.p") != []
    assert Floki.find(doc, "#activities-#{status.id} .kt.p") == []
  end

  test "filtered empty command clears back to the activity feed", %{
    conn: conn,
    current_company: company
  } do
    {:ok, _issue} =
      Cympho.Issues.create_issue(%{title: "System-only event", company_id: company.id})

    {:ok, _view, html} = live(conn, "/activity?filter_actor_type=user")

    # The Filter chip counts the filters in use.
    assert text(main_doc(html), "#activity-filter summary .mono") == "1"
    assert html =~ "No matching activity in this view"
    assert html =~ "Clear filters"
    assert html =~ ~s(href="/activity")
    assert html =~ "Audit lanes"
    assert html =~ "Filtered out"
  end

  test "streams the first page and appends the next on next-page", %{
    conn: conn,
    current_company: company
  } do
    {:ok, issue} =
      Cympho.Issues.create_issue(%{title: "Pagination probe", company_id: company.id})

    seed_markers(company, issue, 51)

    {:ok, view, html} = live(conn, "/activity")

    # Newest (page 1) is shown, oldest (page 2) is not, and the sentinel renders.
    assert html =~ "Marker 051"
    refute html =~ "Marker 001"
    assert html =~ "activity-sentinel"
    assert html =~ ~s(phx-hook="InfiniteScroll")

    # Loading the next page appends the oldest marker.
    view |> element("#activity-sentinel") |> render_hook("next-page")
    assert render(view) =~ "Marker 001"
  end

  test "changing a filter resets the stream to the first page", %{
    conn: conn,
    current_company: company
  } do
    {:ok, issue} = Cympho.Issues.create_issue(%{title: "Filter probe", company_id: company.id})
    seed_markers(company, issue, 51)

    {:ok, view, _html} = live(conn, "/activity")
    view |> element("#activity-sentinel") |> render_hook("next-page")
    assert render(view) =~ "Marker 001"

    # Filtering to a non-matching actor empties the stream (reset, not append).
    html = render_change(view, "filter", %{"filter_action" => "", "filter_actor_type" => "user"})
    refute html =~ "Marker 051"
    assert html =~ "No activity found."
  end
end
