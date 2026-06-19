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

  test "compact board cards hide secondary move controls on mobile" do
    html = render_card("compact")
    class = action_row_class(html)

    assert class =~ "kanban-card-actions"
    assert class =~ "hidden sm:flex"
  end

  test "detailed board cards keep secondary move controls visible" do
    html = render_card("detailed")
    class = action_row_class(html)

    assert class =~ "kanban-card-actions"
    assert class =~ "flex"
    refute class =~ "hidden sm:flex"
  end

  defp action_row_class(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find(".kanban-card-actions")
    |> Floki.attribute("class")
    |> List.first()
  end
end
