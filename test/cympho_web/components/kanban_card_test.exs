defmodule CymphoWeb.Components.KanbanCardTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

  alias Cympho.Issues.Issue

  defp render_card(density) do
    render_component(
      &CymphoWeb.KanbanLive.Components.issue_card/1,
      issue: %Issue{
        id: Ecto.UUID.generate(),
        identifier: "AIL-101",
        title: "Ship compact mobile board cards",
        status: :todo,
        priority: :medium,
        comments: [],
        blocked_by: [],
        assignee: nil
      },
      status: :todo,
      digest_density: density
    )
  end

  test "compact board cards use one accessible move menu" do
    html = render_card("compact")

    assert html =~ ~s(aria-label="Move issue")
    assert html =~ "hero-ellipsis-horizontal-mini"
    refute html =~ "kanban-card-actions"
  end

  test "detailed board cards also avoid repeated move buttons" do
    html = render_card("detailed")

    assert html =~ ~s(aria-label="Move issue")
    assert html =~ "hero-ellipsis-horizontal-mini"
    refute html =~ "kanban-card-actions"
  end
end
