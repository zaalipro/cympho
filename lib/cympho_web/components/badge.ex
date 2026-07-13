defmodule CymphoWeb.Components.Badge do
  use Phoenix.Component

  # {pill classes, dot classes} — status dot + low-alpha tint + hairline so
  # every state reads instantly on any theme canvas. Color families use the
  # channel-form semantic tokens (emerald→success, red→error, amber→warning)
  # so the /10 and /25 alpha tints resolve on every theme.
  @status_colors %{
    "backlog" => {"border border-border bg-surface text-text-tertiary", "bg-text-quaternary"},
    "todo" => {"border border-accent/25 bg-accent/10 text-accent", "bg-accent"},
    "in_progress" => {"border border-brand/30 bg-brand/10 text-brand", "bg-brand animate-pulse"},
    "in_review" =>
      {"border border-violet-500/25 bg-violet-500/10 text-violet-300", "bg-violet-300"},
    "done" =>
      {"border border-emerald-500/25 bg-emerald-500/10 text-emerald-300", "bg-emerald-400"},
    "blocked" => {"border border-red-500/30 bg-red-500/10 text-red-300", "bg-red-400"},
    "open" => {"border border-accent/25 bg-accent/10 text-accent", "bg-accent"},
    "closed" =>
      {"border border-emerald-500/25 bg-emerald-500/10 text-emerald-300", "bg-emerald-400"},
    "active" =>
      {"border border-emerald-500/25 bg-emerald-500/10 text-emerald-300", "bg-emerald-400"},
    "archived" => {"border border-border bg-surface text-text-quaternary", "bg-text-quaternary"}
  }

  @priority_colors %{
    "low" => {"border border-border bg-surface text-text-tertiary", "bg-text-quaternary"},
    "medium" => {"border border-amber-500/25 bg-amber-500/10 text-amber-300", "bg-amber-400"},
    "high" => {"border border-brand/30 bg-brand/10 text-brand", "bg-brand"},
    "critical" => {"border border-red-500/30 bg-red-500/10 text-red-300", "bg-red-400"}
  }

  @agent_colors %{
    "idle" => {"border border-border bg-surface text-text-tertiary", "bg-text-quaternary"},
    "running" => {"border border-brand/30 bg-brand/10 text-brand", "bg-brand animate-pulse"},
    "error" => {"border border-red-500/30 bg-red-500/10 text-red-300", "bg-red-400"},
    "offline" =>
      {"border border-border bg-surface text-text-quaternary", "bg-text-quaternary opacity-60"}
  }

  @default_pair {"border border-border bg-subtle text-text-secondary", "bg-text-quaternary"}

  attr :variant, :string, default: "status"
  attr :value, :string, required: true
  attr :rest, :global

  def badge(assigns) do
    value_str = to_string(assigns.value)

    {class, dot_class} =
      case assigns.variant do
        "status" -> Map.get(@status_colors, value_str, @default_pair)
        "priority" -> Map.get(@priority_colors, value_str, @default_pair)
        "agent" -> Map.get(@agent_colors, value_str, @default_pair)
        "pill" -> {"border border-border text-text-secondary", nil}
        _ -> {"bg-subtle text-text-secondary", nil}
      end

    label = value_str |> String.replace("_", " ") |> String.capitalize()

    assigns =
      assigns
      |> assign(:class, class)
      |> assign(:dot_class, dot_class)
      |> assign(:label, label)

    ~H"""
    <span
      class={[
        "inline-flex items-center gap-1.5 px-2.5 py-0.5 rounded-full text-xs font-510 whitespace-nowrap",
        @class
      ]}
      {@rest}
    >
      <%= if @dot_class do %>
        <span class={["w-1.5 h-1.5 rounded-full shrink-0", @dot_class]}></span>
      <% end %>
      {@label}
    </span>
    """
  end
end
