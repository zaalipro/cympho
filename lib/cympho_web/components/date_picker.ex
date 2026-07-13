defmodule CymphoWeb.Components.DatePicker do
  @moduledoc """
  Theme-matched date / time / datetime pickers — drop-in replacements for the
  browser-native `type="date"`, `type="time"`, and `type="datetime-local"`
  controls, styled with the same tokens and popover language as `select_menu`.

  Architecture (mirrors `CymphoWeb.Components.select_menu/1`):

    * The value vehicle is a **visually-hidden REAL typed `<input>`** (`sr-only`,
      not `type="hidden"`). It posts with the form, fires `phx-change` via a
      bubbling `change`, and stays drivable by `Phoenix.LiveViewTest` (a
      `type="hidden"` input is immutable to LiveViewTest).
    * A styled trigger button shows a human label; the calendar / time grid is
      built client-side by the `DatePicker` hook in `assets/js/app.js`, so the
      hook root is `phx-update="ignore"` and the native input is the source of
      truth after mount.

  Value normalization: the incoming `value` may be a `Date`, `DateTime`,
  `NaiveDateTime`, string, or nil. It is normalized to exactly the ISO string the
  native input expects (`YYYY-MM-DD`, `HH:MM`, or `YYYY-MM-DDTHH:MM`).

  Timezone: values are treated as **naive wall-clock** — we keep the calendar
  fields and drop any offset and seconds. We deliberately do NOT convert
  timezones; `:utc_datetime` fields round-trip the wall-clock the user sees, the
  same as the native `datetime-local` control. Do not "fix" this into UTC
  conversion or everyone's times will shift.
  """
  use Phoenix.Component

  attr :name, :string, required: true
  attr :value, :any, default: nil, doc: "Date | DateTime | NaiveDateTime | string | nil"
  attr :id, :string, default: nil
  attr :disabled, :boolean, default: false
  attr :invalid, :boolean, default: false
  attr :required, :boolean, default: false
  attr :min, :string, default: nil, doc: "\"YYYY-MM-DD\" lower bound"
  attr :max, :string, default: nil, doc: "\"YYYY-MM-DD\" upper bound"
  attr :placeholder, :string, default: nil
  attr :class, :any, default: nil
  attr :minute_step, :integer, default: 5
  attr :rest, :global

  @doc "Calendar date picker → emits `YYYY-MM-DD`."
  def date_picker(assigns) do
    assigns
    |> assign(:value, normalize_date(assigns.value))
    |> assign(:mode, "date")
    |> assign(:input_type, "date")
    |> assign(:icon, "hero-calendar-mini")
    |> assign(:popover_width, "w-[18rem]")
    |> assign(:placeholder, assigns.placeholder || "Select date…")
    |> picker()
  end

  attr :name, :string, required: true
  attr :value, :any, default: nil
  attr :id, :string, default: nil
  attr :disabled, :boolean, default: false
  attr :invalid, :boolean, default: false
  attr :required, :boolean, default: false
  attr :min, :string, default: nil
  attr :max, :string, default: nil
  attr :placeholder, :string, default: nil
  attr :class, :any, default: nil
  attr :minute_step, :integer, default: 5
  attr :rest, :global

  @doc "24-hour time picker (hour:minute columns) → emits `HH:MM`."
  def time_picker(assigns) do
    assigns
    |> assign(:value, normalize_time(assigns.value))
    |> assign(:mode, "time")
    |> assign(:input_type, "time")
    |> assign(:icon, "hero-clock-mini")
    |> assign(:popover_width, "w-[12rem]")
    |> assign(:placeholder, assigns.placeholder || "Select time…")
    |> picker()
  end

  attr :name, :string, required: true
  attr :value, :any, default: nil
  attr :id, :string, default: nil
  attr :disabled, :boolean, default: false
  attr :invalid, :boolean, default: false
  attr :required, :boolean, default: false
  attr :min, :string, default: nil
  attr :max, :string, default: nil
  attr :placeholder, :string, default: nil
  attr :class, :any, default: nil
  attr :minute_step, :integer, default: 5
  attr :rest, :global

  @doc "Combined calendar + 24-hour time → emits `YYYY-MM-DDTHH:MM` (UTC-naive)."
  def datetime_picker(assigns) do
    assigns
    |> assign(:value, normalize_datetime(assigns.value))
    |> assign(:mode, "datetime")
    |> assign(:input_type, "datetime-local")
    |> assign(:icon, "hero-calendar-mini")
    |> assign(:popover_width, "w-[19rem]")
    |> assign(:placeholder, assigns.placeholder || "Select date & time…")
    |> picker()
  end

  # ── Shared markup ──────────────────────────────────────────────────────────

  defp picker(assigns) do
    assigns = assign(assigns, :base_id, picker_id(assigns[:id], assigns.name))

    ~H"""
    <div
      id={"#{@base_id}-picker"}
      phx-hook="DatePicker"
      phx-update="ignore"
      data-picker
      data-picker-mode={@mode}
      data-disabled={to_string(@disabled)}
      data-placeholder={@placeholder}
      data-minute-step={@minute_step}
      data-min={@min}
      data-max={@max}
      class={["relative", @class]}
    >
      <%!-- Value vehicle: a real typed input, visually hidden. Real (not
            type="hidden") so it posts, fires phx-change, and LiveViewTest can
            drive it. The JS hook mirrors picks onto it. --%>
      <input
        type={@input_type}
        data-picker-native
        id={@base_id}
        name={@name}
        value={@value}
        required={@required}
        disabled={@disabled}
        min={@min}
        max={@max}
        tabindex="-1"
        aria-hidden="true"
        class="sr-only"
        {@rest}
      />
      <button
        type="button"
        data-picker-trigger
        disabled={@disabled}
        aria-haspopup="dialog"
        aria-expanded="false"
        class={[
          "flex w-full items-center gap-2 h-9 px-2.5 rounded-input text-left",
          "bg-surface border text-caption text-ink transition duration-150",
          "focus:outline-none focus:ring-2 disabled:opacity-50 disabled:cursor-not-allowed",
          (@invalid && "border-error focus:ring-red-500/40 focus:border-error") ||
            "border-hairline hover:border-hairline-strong focus:ring-primary/30 focus:border-primary focus:shadow-[0_0_16px_-4px_rgb(var(--color-primary-rgb)/0.35)]"
        ]}
      >
        <span class={[@icon, "w-4 h-4 shrink-0 text-ink-tertiary"]} aria-hidden="true"></span>
        <span data-picker-display class="min-w-0 flex-1 truncate text-ink-tertiary">
          {@placeholder}
        </span>
      </button>

      <%!-- Empty shells; the DatePicker hook builds the calendar / time UI in. --%>
      <div
        data-picker-popover
        role="dialog"
        aria-modal="false"
        class={[
          "hidden absolute left-0 top-full z-50 p-2",
          "cympho-menu-panel rounded-lg bg-surface-2 border border-hairline shadow-elevated",
          @popover_width
        ]}
      >
        <div :if={@mode != "time"} data-picker-calendar></div>
        <div
          :if={@mode != "date"}
          data-picker-time
          class={@mode == "datetime" && "mt-2 pt-2 border-t border-hairline"}
        >
        </div>
      </div>
    </div>
    """
  end

  # ── Stable id ────────────────────────────────────────────────────────────────

  defp picker_id(id, _name) when is_binary(id) and id != "", do: id
  defp picker_id(_id, name), do: "picker-" <> slugify(name)

  defp slugify(name) do
    name
    |> to_string()
    |> String.replace(~r/[^a-zA-Z0-9]+/, "_")
    |> String.trim("_")
  end

  # ── Value normalization (naive wall-clock; drop offset + seconds) ────────────

  @doc false
  def normalize_date(nil), do: nil
  def normalize_date(""), do: nil
  def normalize_date(%Date{} = d), do: Date.to_iso8601(d)
  def normalize_date(%DateTime{} = dt), do: Date.to_iso8601(DateTime.to_date(dt))
  def normalize_date(%NaiveDateTime{} = ndt), do: Date.to_iso8601(NaiveDateTime.to_date(ndt))
  def normalize_date(s) when is_binary(s), do: String.slice(s, 0, 10)
  def normalize_date(_), do: nil

  @doc false
  def normalize_time(nil), do: nil
  def normalize_time(""), do: nil
  def normalize_time(%Time{} = t), do: t |> Time.to_iso8601() |> String.slice(0, 5)
  def normalize_time(%DateTime{} = dt), do: normalize_time(DateTime.to_time(dt))
  def normalize_time(%NaiveDateTime{} = ndt), do: normalize_time(NaiveDateTime.to_time(ndt))

  def normalize_time(s) when is_binary(s) do
    case Regex.run(~r/(\d{2}:\d{2})/, s) do
      [_, hhmm] -> hhmm
      _ -> nil
    end
  end

  def normalize_time(_), do: nil

  @doc false
  def normalize_datetime(nil), do: nil
  def normalize_datetime(""), do: nil

  def normalize_datetime(%NaiveDateTime{} = ndt),
    do: ndt |> NaiveDateTime.to_iso8601() |> String.slice(0, 16)

  def normalize_datetime(%DateTime{} = dt), do: dt |> DateTime.to_naive() |> normalize_datetime()
  def normalize_datetime(%Date{} = d), do: Date.to_iso8601(d) <> "T00:00"

  def normalize_datetime(s) when is_binary(s) do
    case Regex.run(~r/(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2})/, s) do
      [_, date, time] ->
        "#{date}T#{time}"

      _ ->
        case normalize_date(s) do
          nil -> nil
          date -> date <> "T00:00"
        end
    end
  end

  def normalize_datetime(_), do: nil
end
