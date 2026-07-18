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

  test "card title and grip are usable drag surfaces" do
    html = render_card("compact")
    document = Floki.parse_document!(html)

    [card] = Floki.find(document, "[data-kanban-card]")
    [title_link] = Floki.find(card, "a[href^='/issues/']")

    assert Floki.find(card, "[data-kanban-drag-handle]") != []
    assert Floki.attribute(title_link, "data-no-drag") == []
    assert Floki.attribute(title_link, "draggable") == ["false"]
  end

  test "sortable configuration drags cards without filtering title links" do
    source = File.read!(Path.join([File.cwd!(), "assets/js/app.js"]))

    assert source =~ ~s(draggable: "[data-kanban-card]")
    assert source =~ ~s(filter: "button, input, textarea, select, details, [data-no-drag]")
    refute source =~ ~s(filter: "a, button, input, textarea, select, [data-no-drag]")
  end
end
