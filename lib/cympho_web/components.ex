defmodule CymphoWeb.Components do
  use Phoenix.Component

  attr :size, :string, default: "wide"
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def page(assigns) do
    ~H"""
    <div class={["min-h-screen bg-canvas px-4 py-5 sm:px-6 lg:px-8", @class]} {@rest}>
      <div class={["mx-auto w-full", page_size(@size)]}>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  attr :title, :string, default: nil
  attr :subtitle, :string, default: nil
  attr :rest, :global
  slot :inner_block
  slot :actions

  def header(assigns) do
    ~H"""
    <header class="mb-5 flex flex-col gap-3 sm:flex-row sm:items-end sm:justify-between" {@rest}>
      <div class="min-w-0">
        <h1 :if={@title} class="text-[22px] leading-7 font-590 tracking-tight text-text-primary">
          {@title}
        </h1>
        <p :if={@subtitle} class="mt-1 max-w-2xl text-sm leading-5 text-text-tertiary">
          {@subtitle}
        </p>
        {render_slot(@inner_block)}
      </div>
      <div :if={@actions != []} class="flex flex-wrap items-center gap-2 sm:justify-end">
        {render_slot(@actions)}
      </div>
    </header>
    """
  end

  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def panel(assigns) do
    ~H"""
    <section class={["rounded-lg border border-border bg-panel shadow-ring", @class]} {@rest}>
      {render_slot(@inner_block)}
    </section>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :hint, :string, default: nil
  attr :tone, :string, default: "default"
  attr :class, :any, default: nil
  attr :rest, :global

  def metric(assigns) do
    ~H"""
    <div class={["rounded-lg border border-border bg-panel px-4 py-3", @class]} {@rest}>
      <p class="text-[11px] font-590 uppercase tracking-[0.08em] text-text-quaternary">
        {@label}
      </p>
      <p class={["mt-1 text-2xl font-590 leading-8", metric_tone(@tone)]}>{@value}</p>
      <p :if={@hint} class="mt-1 truncate text-xs text-text-quaternary">{@hint}</p>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :message, :string, default: nil
  attr :icon, :string, default: nil
  attr :class, :any, default: nil
  slot :icon
  slot :actions

  def empty_state(assigns) do
    ~H"""
    <div class={["flex flex-col items-center justify-center px-6 py-16 text-center", @class]}>
      <div class="mb-4 flex h-10 w-10 items-center justify-center rounded-lg border border-border bg-surface text-text-tertiary">
        <%= if @icon != [] || @icon do %>
          {render_slot(@icon)}
        <% else %>
          <.empty_state_icon icon="default" />
        <% end %>
      </div>
      <p class="text-sm font-590 text-text-primary">{@title}</p>
      <p :if={@message} class="mt-1 max-w-md text-sm leading-5 text-text-tertiary">
        {@message}
      </p>
      <div :if={@actions != []} class="mt-4 flex flex-wrap justify-center gap-2">
        {render_slot(@actions)}
      </div>
    </div>
    """
  end

  attr :icon, :string, required: true

  def empty_state_icon(assigns) do
    ~H"""
    <%= case @icon do %>
      <% "search" -> %>
        <svg class="h-5 w-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z" />
        </svg>
      <% "agent" -> %>
        <svg class="h-5 w-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M17 20h5v-2a3 3 0 00-5.356-1.857M17 20H7m10 0v-2c0-.656-.126-1.283-.356-1.857M7 20H2v-2a3 3 0 015.356-1.857M7 20v-2c0-.656.126-1.283.356-1.857m0 0a5.002 5.002 0 019.288 0M15 7a3 3 0 11-6 0 3 3 0 016 0zm6 3a2 2 0 11-4 0 2 2 0 014 0zM7 10a2 2 0 11-4 0 2 2 0 014 0z" />
        </svg>
      <% "issue" -> %>
        <svg class="h-5 w-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 5H7a2 2 0 00-2 2v12a2 2 0 002 2h10a2 2 0 002-2V7a2 2 0 00-2-2h-2M9 5a2 2 0 002 2h2a2 2 0 002-2M9 5a2 2 0 012-2h2a2 2 0 012 2m-6 9l2 2 4-4" />
        </svg>
      <% "project" -> %>
        <svg class="h-5 w-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M3 7v10a2 2 0 002 2h14a2 2 0 002-2V9a2 2 0 00-2-2h-6l-2-2H5a2 2 0 00-2 2z" />
        </svg>
      <% "goal" -> %>
        <svg class="h-5 w-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 10V3L4 14h7v7l9-11h-7z" />
        </svg>
      <% "document" -> %>
        <svg class="h-5 w-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414A1 1 0 0119 9.414V19a2 2 0 01-2 2z" />
        </svg>
      <% _ -> %>
        <svg class="h-5 w-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M20 13V6a2 2 0 00-2-2H6a2 2 0 00-2 2v7m16 0v5a2 2 0 01-2 2H6a2 2 0 01-2-2v-5m16 0h-2.586a1 1 0 00-.707.293l-2.414 2.414a1 1 0 01-.707.293h-2.172a1 1 0 01-.707-.293l-2.414-2.414A1 1 0 006.586 13H4" />
        </svg>
    <% end %>
    """
  end

  attr :label, :string, default: "Actions"
  attr :align, :string, default: "right"
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def overflow_menu(assigns) do
    ~H"""
    <details class={["linear-menu relative", @class]}>
      <summary
        class="flex h-8 w-8 cursor-pointer list-none items-center justify-center rounded-md text-text-quaternary transition-colors hover:bg-surface-hover hover:text-text-primary"
        aria-label={@label}
      >
        <svg class="h-4 w-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M12 5h.01M12 12h.01M12 19h.01"
          />
        </svg>
      </summary>
      <div class={[
        "linear-menu-panel absolute z-30 mt-2 min-w-44 rounded-lg border border-border bg-panel p-1 shadow-dialog",
        menu_align(@align)
      ]}>
        {render_slot(@inner_block)}
      </div>
    </details>
    """
  end

  attr :navigate, :string, default: nil
  attr :type, :string, default: "button"
  attr :danger, :boolean, default: false
  attr :rest, :global
  slot :inner_block, required: true

  def menu_item(%{navigate: navigate} = assigns) when is_binary(navigate) do
    ~H"""
    <.link
      navigate={@navigate}
      class={[
        "flex w-full items-center rounded-md px-2.5 py-2 text-left text-sm transition-colors",
        if(@danger,
          do: "text-red-300 hover:bg-red-500/10",
          else: "text-text-secondary hover:bg-surface-hover hover:text-text-primary"
        )
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  def menu_item(assigns) do
    ~H"""
    <button
      type={@type}
      class={[
        "flex w-full items-center rounded-md px-2.5 py-2 text-left text-sm transition-colors",
        if(@danger,
          do: "text-red-300 hover:bg-red-500/10",
          else: "text-text-secondary hover:bg-surface-hover hover:text-text-primary"
        )
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  attr :navigate, :string, required: true
  attr :class, :string, default: ""
  attr :rest, :global
  slot :inner_block, required: true

  def app_link(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class={["text-text-secondary hover:text-text-primary transition-colors", @class]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  attr :for, :any, required: true
  attr :as, :any, default: :global
  attr :rest, :global, include: ~w(method action)
  slot :inner_block, required: true
  slot :actions

  def simple_form(assigns) do
    ~H"""
    <form {@rest}>
      {render_slot(@inner_block)}
      <div :if={@actions != []} class="form-actions">
        {render_slot(@actions)}
      </div>
    </form>
    """
  end

  attr :field, :any, default: nil
  attr :label, :string, default: nil
  attr :type, :string, default: "text"
  attr :required, :boolean, default: false
  attr :disabled, :boolean, default: false
  attr :rows, :integer, default: nil
  attr :options, :list, default: nil
  attr :step, :string, default: nil
  attr :max, :string, default: nil
  attr :min, :string, default: nil
  attr :name, :string, default: nil
  attr :value, :any, default: nil
  attr :phx_change, :string, default: nil
  attr :id, :string, default: nil
  attr :rest, :global

  def input(assigns) do
    assigns = assign(assigns, :errors, input_errors(assigns.field))

    error_id = input_error_id(assigns.field, assigns.name, assigns.id)
    has_errors = assigns.errors != []

    ~H"""
    <div class="space-y-1.5">
      <label :if={@label} for={input_id(@field, @id)} class="block text-xs font-510 text-text-secondary">{@label}</label>
      <textarea
        :if={@type == "textarea"}
        id={input_id(@field, @id)}
        name={input_name(@field, @name)}
        rows={@rows}
        aria-describedby={has_errors && error_id}
        aria-invalid={has_errors}
        class={[
          "w-full bg-surface border rounded-lg px-3.5 py-2 text-sm text-text-primary placeholder:text-text-quaternary focus:outline-none focus:ring-2 focus:ring-brand/30 focus:border-brand transition-colors",
          input_border_class(@errors)
        ]}
        {@rest}
      ><%= input_value(@field, @value) %></textarea>
      <select
        :if={@type == "select"}
        id={input_id(@field, @id)}
        name={input_name(@field, @name)}
        required={@required}
        disabled={@disabled}
        aria-describedby={has_errors && error_id}
        aria-invalid={has_errors}
        class={[
          "w-full bg-surface border rounded-lg px-3.5 py-2 text-sm text-text-primary focus:outline-none focus:ring-2 focus:ring-brand/30 focus:border-brand transition-colors",
          input_border_class(@errors)
        ]}
        {@rest}
      >
        <option
          :for={{label, value} <- select_options(@options)}
          value={value}
          selected={to_string(input_value(@field, @value)) == to_string(value)}
        >
          {label}
        </option>
      </select>
      <input
        :if={@type not in ["textarea", "select"]}
        id={input_id(@field, @id)}
        type={@type}
        name={input_name(@field, @name)}
        value={input_value(@field, @value)}
        required={@required}
        disabled={@disabled}
        aria-describedby={has_errors && error_id}
        aria-invalid={has_errors}
        class={[
          "w-full bg-surface border rounded-lg px-3.5 py-2 text-sm text-text-primary placeholder:text-text-quaternary focus:outline-none focus:ring-2 focus:ring-brand/30 focus:border-brand transition-colors",
          input_border_class(@errors)
        ]}
        {@rest}
      />
      <p :if={has_errors} id={error_id} class="text-xs text-error" aria-live="polite">
        <%= Enum.at(@errors, 0) %>
      </p>
    </div>
    """
  end

  attr :type, :string, default: "submit"
  attr :variant, :string, default: nil
  attr :size, :string, default: nil
  attr :disabled, :boolean, default: false
  attr :rest, :global
  slot :inner_block, required: true

  def button(assigns) do
    ~H"""
    <button
      type={@type}
      disabled={@disabled}
      class={[
        "inline-flex items-center justify-center gap-2 font-medium transition-colors rounded-lg",
        button_variant(@variant),
        button_size(@size),
        @disabled && "cursor-not-allowed opacity-50"
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :options, :list, required: true
  attr :value, :string, default: nil
  attr :required, :boolean, default: false
  attr :rest, :global

  def select(assigns) do
    ~H"""
    <div class="space-y-1.5">
      <label class="block text-xs font-510 text-text-secondary">{@label}</label>
      <select
        name={@name}
        class="w-full bg-surface border border-border rounded-lg px-3.5 py-2 text-sm text-text-primary focus:outline-none focus:ring-2 focus:ring-brand/30 focus:border-brand transition-colors appearance-none"
        {@rest}
      >
        <option
          :for={{label, value} <- Enum.map(@options, fn {k, v} -> {to_string(k), v} end)}
          value={value}
          selected={@value == value}
        >
          {label}
        </option>
      </select>
    </div>
    """
  end

  defp input_name(_field, name) when is_binary(name), do: name
  defp input_name(%{name: name}, _name), do: name
  defp input_name(_, _), do: nil

  defp input_value(_field, value) when not is_nil(value), do: value
  defp input_value(%{value: value}, _value), do: value
  defp input_value(_, _), do: nil

  defp select_options(nil), do: []

  defp select_options(options) do
    Enum.map(options, fn
      {label, value} -> {label, value}
      value -> {value, value}
    end)
  end

  defp button_variant("primary"), do: "bg-brand text-white hover:bg-accent"

  defp button_variant("secondary"),
    do: "bg-button text-text-primary border border-border hover:bg-button-hover"

  defp button_variant("ghost"), do: "text-text-secondary hover:bg-surface-hover"
  defp button_variant("danger"), do: "bg-error text-white hover:bg-red-600"

  defp button_variant(_),
    do: "bg-button text-text-primary border border-border hover:bg-button-hover"

  defp button_size("sm"), do: "px-3 py-1.5 text-xs"
  defp button_size("lg"), do: "px-6 py-3 text-base"
  defp button_size(_), do: "px-4 py-2 text-sm"

  attr :field, :any, required: true

  def error(assigns) do
    assigns = assign(assigns, :errors, input_errors(assigns.field))

    ~H"""
    <div :for={error <- @errors} class="text-xs text-error mt-1">
      {error}
    </div>
    """
  end

  defp input_errors(nil), do: []
  defp input_errors(%{errors: errors}), do: Enum.map(errors, &format_input_error/1)
  defp input_errors(_), do: []

  defp format_input_error({message, opts}) when is_binary(message) and is_list(opts) do
    Enum.reduce(opts, message, fn
      {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))

      _, acc ->
        acc
    end)
  end

  defp format_input_error(message) when is_binary(message), do: message
  defp format_input_error(message), do: inspect(message)

  defp input_border_class([]), do: "border-border"
  defp input_border_class(_), do: "border-error/60"

  defp input_error_id(field, name, id) when is_binary(id), do: "#{id}-error"
  defp input_error_id(field, name, _id), do: "input-error-#{input_name(field, name) || "unknown"}"

  defp input_id(%{id: id}, _name), do: id
  defp input_id(_field, id) when is_binary(id), do: id
  defp input_id(_, _), do: nil

  defp page_size("form"), do: "max-w-3xl"
  defp page_size("content"), do: "max-w-6xl"
  defp page_size("wide"), do: "max-w-7xl"
  defp page_size("full"), do: "max-w-none"
  defp page_size(_), do: "max-w-7xl"

  defp metric_tone("brand"), do: "text-brand"
  defp metric_tone("success"), do: "text-success"
  defp metric_tone("warning"), do: "text-amber-300"
  defp metric_tone("danger"), do: "text-red-300"
  defp metric_tone(_), do: "text-text-primary"

  defp menu_align("left"), do: "left-0"
  defp menu_align(_), do: "right-0"
end
