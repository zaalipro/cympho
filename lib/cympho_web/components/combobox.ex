defmodule CymphoWeb.Components.Combobox do
  @moduledoc """
  Searchable combobox / multi-select.

  Pairs with the `Combobox` JS hook (assets/js/app.js) which handles
  open/close, keyboard navigation, and search filtering. The component
  emits a `phx-change` event with the selected ids when the selection
  changes.

  ## Examples

      <.combobox
        id="filter-status"
        label="Status"
        options={[%{id: "todo", label: "Todo"}, %{id: "done", label: "Done"}]}
        selected={@selected_status}
        on_change="filter_status_changed"
        multi?={true}
        placeholder="Status"
      />

  Options are `%{id, label, icon?, color?}` maps. The `on_change`
  string names a `handle_event/3` clause that receives `%{"selected" =>
  [ids]}` (multi) or `%{"selected" => id | nil}` (single).
  """
  use Phoenix.Component

  attr :id, :string, required: true
  attr :label, :string, default: nil
  attr :placeholder, :string, default: "Select…"
  attr :options, :list, required: true
  attr :selected, :any, default: nil
  attr :on_change, :string, required: true
  attr :multi?, :boolean, default: false
  attr :searchable?, :boolean, default: true
  attr :clearable?, :boolean, default: true
  attr :align, :string, default: "left", values: ~w(left right)
  attr :class, :string, default: nil
  attr :rest, :global

  def combobox(assigns) do
    selected_ids = normalize_selected(assigns.selected)
    selected_options = Enum.filter(assigns.options, &(&1.id in selected_ids))

    assigns =
      assigns
      |> assign(:selected_ids, selected_ids)
      |> assign(:selected_options, selected_options)
      |> assign(:trigger_label, trigger_label(assigns, selected_options))

    ~H"""
    <div
      id={@id}
      class={["relative inline-block", @class]}
      phx-hook="Combobox"
      data-combobox-multi={to_string(@multi?)}
      data-combobox-onchange={@on_change}
      {@rest}
    >
      <button
        type="button"
        data-combobox-trigger
        class={[
          "inline-flex items-center gap-1.5 px-2.5 h-7 rounded-md max-w-full",
          "text-caption text-ink whitespace-nowrap",
          "bg-surface-1 hover:bg-surface-2 border border-hairline",
          "transition-colors duration-100",
          "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary focus-visible:ring-offset-2 focus-visible:ring-offset-canvas",
          length(@selected_ids) > 0 && "border-hairline-strong"
        ]}
        aria-haspopup="listbox"
        aria-expanded="false"
      >
        <span :if={@label} class="text-ink-muted shrink-0">{@label}:</span>
        <span class="font-510 truncate">{@trigger_label}</span>
        <.chevron />
      </button>

      <div
        data-combobox-popover
        class={[
          "hidden absolute z-50 mt-1 w-64 rounded-lg",
          "bg-surface-2 border border-hairline shadow-elevated",
          "overflow-hidden",
          @align == "right" && "right-0",
          @align == "left" && "left-0"
        ]}
        role="listbox"
        aria-multiselectable={to_string(@multi?)}
      >
        <div :if={@searchable?} class="p-2 border-b border-hairline">
          <input
            type="text"
            data-combobox-search
            placeholder="Search…"
            class={[
              "w-full px-2 h-7 rounded-sm bg-surface-1",
              "text-caption text-ink placeholder:text-ink-tertiary",
              "border border-hairline focus:border-primary focus:outline-none"
            ]}
            autocomplete="off"
          />
        </div>

        <ul data-combobox-list class="max-h-64 overflow-y-auto py-1" role="presentation">
          <li
            :for={opt <- @options}
            data-combobox-option
            data-combobox-id={opt.id}
            data-combobox-label={opt.label}
            data-combobox-selected={to_string(opt.id in @selected_ids)}
            class={[
              "flex items-center gap-2 px-2.5 h-7 mx-1 rounded-sm cursor-pointer",
              "text-caption text-ink",
              "hover:bg-surface-3 data-[combobox-active=true]:bg-surface-3"
            ]}
            role="option"
            aria-selected={to_string(opt.id in @selected_ids)}
          >
            <span
              :if={@multi?}
              class={[
                "inline-flex w-4 h-4 rounded-xs items-center justify-center",
                "border border-hairline-strong",
                opt.id in @selected_ids && "bg-primary border-primary"
              ]}
            >
              <span :if={opt.id in @selected_ids} class="hero-check-mini text-white w-3 h-3" />
            </span>
            <span :if={Map.get(opt, :color)} class={["w-2 h-2 rounded-pill", Map.get(opt, :color)]} />
            <span
              :if={Map.get(opt, :icon)}
              class={[Map.get(opt, :icon), "w-3.5 h-3.5 text-ink-muted"]}
            />
            <span class="flex-1 truncate">{opt.label}</span>
            <span
              :if={!@multi? and opt.id in @selected_ids}
              class="hero-check-mini text-primary w-4 h-4"
            />
          </li>
          <li data-combobox-empty class="hidden px-3 py-3 text-caption text-ink-tertiary text-center">
            No results
          </li>
        </ul>

        <div
          :if={@clearable? and length(@selected_ids) > 0}
          class="border-t border-hairline p-1"
        >
          <button
            type="button"
            data-combobox-clear
            class="w-full px-2.5 h-7 rounded-sm text-caption text-ink-muted hover:bg-surface-3 hover:text-ink text-left"
          >
            Clear selection
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp normalize_selected(nil), do: []
  defp normalize_selected(""), do: []
  defp normalize_selected(list) when is_list(list), do: Enum.map(list, &to_string/1)
  defp normalize_selected(value), do: [to_string(value)]

  defp trigger_label(%{placeholder: placeholder}, []), do: placeholder

  defp trigger_label(%{multi?: false}, [opt]), do: opt.label

  defp trigger_label(%{multi?: true}, [opt]), do: opt.label

  defp trigger_label(%{multi?: true}, [first | rest]),
    do: "#{first.label} +#{length(rest)}"

  defp trigger_label(_, _), do: ""

  defp chevron(assigns) do
    ~H"""
    <span class="hero-chevron-down-mini text-ink-tertiary w-3.5 h-3.5" />
    """
  end
end
