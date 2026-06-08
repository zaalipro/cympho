defmodule CymphoWeb.Components.DatePickerTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

  alias CymphoWeb.Components.DatePicker

  defp date(opts), do: render_component(&DatePicker.date_picker/1, opts)
  defp time(opts), do: render_component(&DatePicker.time_picker/1, opts)
  defp datetime(opts), do: render_component(&DatePicker.datetime_picker/1, opts)

  describe "date_picker" do
    test "renders a REAL type=date input (not hidden) carrying the normalized value" do
      html = date(name: "due_on", value: ~D[2026-06-05])
      assert html =~ ~s(type="date")
      assert html =~ ~s(name="due_on")
      assert html =~ "data-picker-native"
      assert html =~ ~s(value="2026-06-05")
      refute html =~ ~s(type="hidden")
    end

    test "normalizes DateTime / NaiveDateTime / string down to the date part" do
      assert date(name: "d", value: ~U[2026-06-05 14:30:00Z]) =~ ~s(value="2026-06-05")
      assert date(name: "d", value: ~N[2026-06-05 14:30:00]) =~ ~s(value="2026-06-05")
      assert date(name: "d", value: "2026-06-05T14:30:00") =~ ~s(value="2026-06-05")
    end

    test "shows the placeholder (muted) when there is no value" do
      html = date(name: "d", placeholder: "Pick a day")
      assert html =~ ~r/data-picker-display[^>]*text-ink-tertiary[^>]*>\s*Pick a day/
    end
  end

  describe "time_picker" do
    test "emits HH:MM (24h), dropping seconds" do
      assert time(name: "t", value: ~T[14:30:00]) =~ ~s(value="14:30")
      assert time(name: "t", value: ~U[2026-06-05 09:05:00Z]) =~ ~s(value="09:05")
      assert time(name: "t", value: "14:30:00") =~ ~s(value="14:30")
    end

    test "uses a real type=time input and clock icon" do
      html = time(name: "t")
      assert html =~ ~s(type="time")
      assert html =~ "hero-clock-mini"
      assert html =~ ~s(data-picker-mode="time")
    end
  end

  describe "datetime_picker (budget edit regression)" do
    test "emits YYYY-MM-DDTHH:MM with NO offset and NO seconds" do
      html = datetime(name: "period_start", value: ~U[2026-06-05 14:30:00Z])
      assert html =~ ~s(value="2026-06-05T14:30")
      # the old broken render leaked "2025-06-05 14:30:00Z" into a datetime-local
      refute html =~ "14:30:00"
      refute html =~ "14:30:00Z"
    end

    test "accepts NaiveDateTime and Date, blanks on nil" do
      assert datetime(name: "p", value: ~N[2026-06-05 14:30:00]) =~ ~s(value="2026-06-05T14:30")
      assert datetime(name: "p", value: ~D[2026-06-05]) =~ ~s(value="2026-06-05T00:00")
      html = datetime(name: "p", value: nil)
      assert html =~ ~s(type="datetime-local")
      refute html =~ ~r/data-picker-native[^>]*value="[^"]/
    end
  end

  describe "wrapper" do
    test "invalid toggles the error border on the trigger" do
      assert date(name: "d", invalid: true) =~ "border-error"
      refute date(name: "d", invalid: false) =~ "border-error"
    end

    test "id is stable and derived from name when absent" do
      a = date(name: "budget[period_start]")
      b = date(name: "budget[period_start]")
      assert a =~ "picker-budget_period_start"
      assert a == b
    end

    test "an explicit id is used verbatim on the native input (for label association)" do
      html = date(name: "due_on", id: "issue_due_on")
      assert html =~ ~s(id="issue_due_on")
      assert html =~ ~s(id="issue_due_on-picker")
    end
  end

  describe "input/1 delegation" do
    test "type=datetime-local delegates to the datetime picker exactly once" do
      html =
        render_component(&CymphoWeb.Components.input/1,
          type: "datetime-local",
          name: "budget[period_start]",
          id: "budget_period_start",
          value: ~U[2026-06-05 14:30:00Z],
          label: "Period Start"
        )

      assert html =~ "Period Start"
      assert html =~ ~s(data-picker-mode="datetime")

      # exactly one datetime-local input — the picker's native one, not a duplicate generic input
      assert length(String.split(html, ~s(type="datetime-local"))) - 1 == 1
      assert html =~ ~s(value="2026-06-05T14:30")
    end

    test "type=date delegates to the date picker" do
      html =
        render_component(&CymphoWeb.Components.input/1,
          type: "date",
          name: "issue[due_on]",
          id: "issue_due_on",
          value: ~D[2026-06-05],
          label: "Due date"
        )

      assert html =~ "Due date"
      assert html =~ ~s(data-picker-mode="date")
      assert html =~ ~s(value="2026-06-05")
    end
  end
end
