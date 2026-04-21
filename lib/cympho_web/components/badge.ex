defmodule CymphoWeb.Components.Badge do
  use Phoenix.Component

  @status_colors %{
    "backlog" => "bg-text-tertiary/20 text-text-tertiary",
    "todo" => "bg-accent/20 text-accent",
    "in_progress" => "bg-brand/20 text-brand",
    "in_review" => "bg-text-secondary/20 text-text-secondary",
    "done" => "bg-success/20 text-success",
    "blocked" => "bg-red-500/20 text-red-400",
    "open" => "bg-accent/20 text-accent",
    "closed" => "bg-success/20 text-success",
    "active" => "bg-success/20 text-success",
    "archived" => "bg-text-quaternary/20 text-text-quaternary",
  }

  @priority_colors %{
    "low" => "bg-text-tertiary",
    "medium" => "bg-amber-500",
    "high" => "bg-red-500",
  }

  @agent_colors %{
    "idle" => "bg-text-tertiary/20 text-text-tertiary",
    "running" => "bg-brand/20 text-brand",
    "error" => "bg-red-500/20 text-red-400",
    "offline" => "bg-text-quaternary/20 text-text-quaternary",
  }

  attr :variant, :string, default: "status"
  attr :value, :string, required: true
  attr :rest, :global

  def badge(assigns) do
    value_str = to_string(assigns.value)

    class =
      case assigns.variant do
        "status" -> Map.get(@status_colors, value_str, "bg-white/10 text-text-secondary")
        "priority" -> Map.get(@priority_colors, value_str, "bg-white/10")
        "agent" -> Map.get(@agent_colors, value_str, "bg-white/10 text-text-secondary")
        "pill" -> "border border-border text-text-secondary"
        _ -> "bg-white/10 text-text-secondary"
      end

    dot_class = Map.get(@priority_colors, value_str, "bg-white/10")
    label = value_str |> String.replace("_", " ") |> String.capitalize()

    assigns =
      assigns
      |> assign(:class, class)
      |> assign(:dot_class, dot_class)
      |> assign(:label, label)

    ~H"""
    <span class={["inline-flex items-center gap-1.5 px-2 py-0.5 rounded text-xs font-510", @class]} {@rest}>
      <%= if @variant == "priority" do %>
        <span class={["w-1.5 h-1.5 rounded-full", @dot_class]}></span>
      <% end %>
      <%= @label %>
    </span>
    """
  end
end
