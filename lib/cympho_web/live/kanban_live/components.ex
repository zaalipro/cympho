defmodule CymphoWeb.KanbanLive.Components do
  use Phoenix.Component
  alias CymphoWeb.KanbanLive.Index
  attr :issue, :map, required: true
  attr :status, :atom, required: true
  attr :agent_heartbeat_states, :map, required: true
  attr :issues, :list, required: true
  def issue_card(assigns) do
    ~H"""
    <div class="bg-white/[0.02] border border-border rounded-md p-3 space-y-2 hover:bg-white/[0.04] transition-colors cursor-grab active:cursor-grabbing" data-issue-id={@issue.id}>
      <div class="text-sm font-510 text-text-primary leading-snug line-clamp-1"><%= @issue.title %></div>
      <div class="flex items-center gap-2 flex-wrap">
        <span class={"text-[10px] font-510 px-2 py-0.5 rounded-full " <> priority_class(@issue.priority)}><%= @issue.priority %></span>
        <span class="text-xs text-text-quaternary"><%= length(@issue.comments) %> comments</span>
        <%= if @issue.assignee do %>
          <span class="text-xs text-text-quaternary truncate max-w-[100px]"><%= @issue.assignee.name %></span>
        <% end %>
        <%= if @issue.github_pr_url do %>
          <a href={@issue.github_pr_url} target="_blank" class="text-xs text-accent hover:text-accent-hover">PR</a>
        <% end %>
      </div>
    </div>
    """
  end
  defp priority_class(:high), do: "bg-red-500/20 text-red-400"
  defp priority_class(:medium), do: "bg-yellow-500/20 text-yellow-400"
  defp priority_class(:low), do: "bg-emerald-500/20 text-emerald-400"
  defp priority_class(_), do: "bg-white/[0.05] text-text-quaternary"
end
