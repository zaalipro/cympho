defmodule CymphoWeb.Components.InputTest do
  @moduledoc """
  `CymphoWeb.Components.input/1` in Paper & Ink (v7 §3.1 B6): a `.fld` wrapper,
  a label tied to the control, one help line, the changeset error as an `.err`
  line, and both described on the control.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  defp doc(opts) do
    (&CymphoWeb.Components.input/1)
    |> render_component(opts)
    |> Floki.parse_fragment!()
  end

  defp attr_of(node, name), do: node |> Floki.attribute(name) |> List.first()

  defp field(errors) do
    form = Phoenix.Component.to_form(%{"name" => "Invoicing app"}, as: :project, errors: errors)
    form[:name]
  end

  test "wraps the field in .fld and ties the label to the control" do
    html = doc(field: field([]), label: "Name", required: true, autocomplete: "off")

    assert [wrapper] = Floki.find(html, "div.fld")
    assert [label] = Floki.find(wrapper, "label")
    assert [input] = Floki.find(wrapper, "input")
    assert attr_of(label, "for") == "project_name"
    assert attr_of(input, "id") == "project_name"
    assert attr_of(input, "name") == "project[name]"
    assert attr_of(input, "value") == "Invoicing app"
    assert attr_of(input, "required") != nil
    assert attr_of(input, "autocomplete") == "off"
    assert attr_of(input, "class") == nil
  end

  test "a wrapper class spans the grid" do
    html = doc(name: "q", id: "q", label: "Details", wrapper_class: "full")

    assert [wrapper] = Floki.find(html, "div.fld")
    assert String.split(attr_of(wrapper, "class")) == ["fld", "full"]
  end

  test "help and error ids are both in aria-describedby; invalid only with an error" do
    clean = doc(field: field([]), label: "Name", help: "Shown on every task.")

    assert [help] = Floki.find(clean, "p.help#project_name-help")
    assert Floki.text(help) == "Shown on every task."
    assert [input] = Floki.find(clean, "input")
    assert attr_of(input, "aria-describedby") == "project_name-help"
    assert attr_of(input, "aria-invalid") == nil
    assert Floki.find(clean, ".err") == []

    invalid =
      doc(
        field: field(name: {"can't be blank", [validation: :required]}),
        id: "project-name",
        label: "Name",
        help: "Shown on every task."
      )

    assert [input] = Floki.find(invalid, "input")
    assert attr_of(input, "aria-invalid") == "true"
    assert attr_of(input, "aria-describedby") == "project-name-help project-name-error"
    assert [err] = Floki.find(invalid, "p.err#project-name-error")
    assert attr_of(err, "aria-live") == "polite"
    assert Floki.text(err) =~ "can't be blank"
    assert Floki.find(err, "use[href='#i-alert']") != []
  end

  test "an error without help describes the control by the error alone" do
    html = doc(field: field(name: {"is too long", []}), label: "Name")

    assert [input] = Floki.find(html, "input")
    assert attr_of(input, "aria-describedby") == "input-error-project[name]"
  end

  test "number fields keep step, min and max" do
    html =
      doc(
        type: "number",
        name: "config[temperature]",
        id: "adapter-config-temperature",
        label: "Temperature",
        step: "any",
        min: "0",
        max: "2",
        value: 0.7
      )

    assert [input] = Floki.find(html, "input[type='number']")
    assert attr_of(input, "step") == "any"
    assert attr_of(input, "min") == "0"
    assert attr_of(input, "max") == "2"
    assert attr_of(input, "value") == "0.7"
  end

  test "disabled and required reach the control" do
    html = doc(name: "key", id: "key", label: "Key", disabled: true, required: true)

    assert [input] = Floki.find(html, "input")
    assert attr_of(input, "disabled") != nil
    assert attr_of(input, "required") != nil
  end

  test "a textarea is a plain control in the same wrapper" do
    html = doc(type: "textarea", name: "description", id: "desc", label: "Details", rows: 8)

    assert [textarea] = Floki.find(html, ".fld textarea#desc")
    assert attr_of(textarea, "rows") == "8"
    assert attr_of(textarea, "class") == nil
  end

  test "a checkbox posts the hidden false and keeps its label beside the box" do
    html = doc(type: "checkbox", name: "hard_stop", id: "hard-stop", label: "Stop at the limit")

    assert [label] = Floki.find(html, ".fld label.fld-ck")
    assert [hidden] = Floki.find(label, "input[type='hidden']")
    assert attr_of(hidden, "name") == "hard_stop"
    assert attr_of(hidden, "value") == "false"
    assert [box] = Floki.find(label, "input[type='checkbox']")
    assert attr_of(box, "value") == "true"
    assert attr_of(box, "id") == "hard-stop"
    assert Floki.text(label) =~ "Stop at the limit"
  end

  test "a select delegates to select_menu with the label and help on its trigger" do
    html =
      doc(
        type: "select",
        name: "budget[period]",
        id: "budget-period",
        label: "Period",
        help: "Resets on the 1st.",
        options: [{"Monthly", "monthly"}, {"Weekly", "weekly"}],
        value: "monthly"
      )

    assert [_] = Floki.find(html, ".fld [data-select-menu]")
    assert [native] = Floki.find(html, "select[data-select-native]")
    assert attr_of(native, "id") == "budget-period"
    assert attr_of(native, "name") == "budget[period]"
    assert [trigger] = Floki.find(html, "button[data-select-trigger]")
    assert attr_of(trigger, "aria-label") == "Period"
    assert attr_of(trigger, "aria-describedby") == "budget-period-help"
    assert String.split(attr_of(trigger, "class")) == ["fld-sel"]
  end

  test "a date field names and describes the picker's trigger" do
    html =
      doc(
        type: "date",
        name: "goal[target_date]",
        id: "goal-target-date",
        label: "Target date",
        help: "Optional."
      )

    assert [trigger] = Floki.find(html, "button[data-picker-trigger]")
    assert attr_of(trigger, "aria-label") == "Target date"
    assert attr_of(trigger, "aria-describedby") == "goal-target-date-help"
  end
end
