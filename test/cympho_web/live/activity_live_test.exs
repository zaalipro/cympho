defmodule CymphoWeb.ActivityLiveTest do
  use CymphoWeb.LiveCase, async: true

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

  test "shows the empty state when there are no activities", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/activity")
    assert html =~ "No activity found."
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
