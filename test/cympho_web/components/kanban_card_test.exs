defmodule CymphoWeb.Components.KanbanCardTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

  alias Cympho.Issues.Issue

  # r3: the Board card (build-spec §5) reads the owner-facing state from a
  # Tasks context; an empty one means nothing on this card needs the owner.
  defp render_card(density) do
    render_component(
      &CymphoWeb.KanbanLive.Components.board_card/1,
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
      ctx: CymphoWeb.IssueLive.Tasks.context(nil, nil, []),
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

    # r3: the whole card is the drag surface (no separate grip); the title link
    # starts a drag rather than a native link drag.
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
