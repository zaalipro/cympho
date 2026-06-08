defmodule CymphoWeb.Components.SelectMenuTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

  defp render_menu(assigns) do
    render_component(&CymphoWeb.Components.select_menu/1, assigns)
  end

  test "renders a real <select> carrying the selected value" do
    html =
      render_menu(
        name: "status",
        value: "todo",
        options: [{"Backlog", "backlog"}, {"To Do", "todo"}]
      )

    assert html =~ ~s(name="status")
    assert html =~ "data-select-native"
    # the native option for the bound value is marked selected (testable / no-JS)
    assert html =~ ~r/<option value="todo"[^>]*selected/
  end

  test "trigger shows the label of the selected option" do
    html =
      render_menu(
        name: "status",
        value: "todo",
        options: [{"Backlog", "backlog"}, {"To Do", "todo"}]
      )

    assert html =~ ~r/data-select-display[^>]*>\s*To Do/
  end

  test "marks the selected option and hides other checkmarks" do
    html =
      render_menu(
        name: "status",
        value: "todo",
        options: [{"Backlog", "backlog"}, {"To Do", "todo"}]
      )

    assert html =~ ~s(data-select-option-value="todo")
    # selected option: data-select-selected="true"
    assert html =~ ~r/data-select-option-value="todo"[^>]*data-select-selected="true"/
    # unselected option carries an invisible checkmark
    assert html =~ ~r/data-select-check[^>]*invisible/
  end

  test "falls back to the placeholder when no value matches" do
    html = render_menu(name: "p", options: [{"One", "1"}], placeholder: "Pick one")
    assert html =~ ~r/data-select-display[^>]*text-ink-tertiary[^>]*>\s*Pick one/
  end

  test "normalizes map and bare-value option shapes" do
    html = render_menu(name: "a", value: "x", options: [%{label: "Ex", value: "x"}, "y"])
    assert html =~ ~s(data-select-option-value="x")
    assert html =~ ~s(data-select-option-label="Ex")
    # bare value becomes both label and value
    assert html =~ ~s(data-select-option-value="y")
    assert html =~ ~s(data-select-option-label="y")
  end

  test "labeled select/1 wrapper delegates to the styled menu" do
    html =
      render_component(&CymphoWeb.Components.select/1,
        name: "role",
        label: "Role",
        value: "eng",
        options: [{"Engineer", "eng"}]
      )

    assert html =~ "Role"
    assert html =~ "data-select-menu"
    assert html =~ ~s(name="role")
  end
end
