defmodule CymphoWeb.KanbanLive.Components do
  use Phoenix.Component
  alias CymphoWeb.KanbanLive.Index

  attr :issue, :map, required: true
  attr :status, :atom, required: true
  attr :agents, :list, required: true
  attr :agent_heartbeat_states, :map, required: true
  attr :editing_card_id, :any, required: true
  attr :card_action_open, :any, required: true

  def issue_card(assigns) do
    ~H"""
    <div class="bg-white/[0.02] border border-border rounded-md p-3 space-y-2 hover:bg-white/[0.04] transition-colors relative" data-issue-id={@issue.id}>
      <%!-- Title / inline edit --%>
      <%= if @editing_card_id == {:edit_title, @issue.id} do %>
        <form phx-submit="save_title" phx-click-away="cancel_edit_title" phx-value-issue-id={@issue.id} class="space-y-1">
          <input
            type="text"
            name="title"
            value={@issue.title}
            class="w-full bg-white/[0.08] border border-accent/40 rounded px-2 py-1 text-sm text-text-primary focus:outline-none focus:ring-1 focus:ring-accent"
            autofocus
          />
          <div class="flex gap-1">
            <button type="submit" class="text-[10px] bg-accent/20 text-accent px-2 py-0.5 rounded">Save</button>
            <button type="button" phx-click="cancel_edit_title" class="text-[10px] bg-white/[0.05] text-text-secondary px-2 py-0.5 rounded">Cancel</button>
          </div>
        </form>
      <% else %>
        <div class="text-sm font-510 text-text-primary leading-snug"><%= @issue.title %></div>
      <% end %>

      <div class="flex items-center gap-2 flex-wrap">
        <.badge variant="priority" value={to_string(@issue.priority)} />
        <span class="text-xs text-text-quaternary flex items-center gap-1">
          <svg class="w-3 h-3" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M7 8h10M7 12h4m1 8l-4-4H5a2 2 0 01-2-2V6a2 2 0 012-2h14a2 2 0 012 2v8a2 2 0 01-2 2h-3l-4 4z"/></svg>
          <%= length(@issue.comments) %>
        </span>
        <%= if @issue.assignee do %>
          <% _hb_state = Index.get_heartbeat_state(@agent_heartbeat_states, @issue.assignee.id) %>
          <span class="text-xs text-text-quaternary truncate max-w-[140px]">
            <%= @issue.assignee.name %>
          </span>
        <% end %>
        <%= if @issue.github_pr_url do %>
          <a href={@issue.github_pr_url} target="_blank" class="text-xs text-accent hover:text-accent-hover transition-colors" title="GitHub PR">PR</a>
        <% end %>
      </div>

      <%!-- Transitions + quick actions row --%>
      <div class="flex items-center justify-between pt-1">
        <div class="flex flex-wrap gap-1.5">
          <%= for next_status <- Index.valid_next_statuses(@status) do %>
            <button
              type="button"
              class="text-[10px] font-510 bg-white/[0.05] hover:bg-white/[0.08] border border-border text-text-tertiary hover:text-text-secondary px-2 py-1 rounded transition-colors"
              phx-click="transition_issue"
              phx-value-id={@issue.id}
              phx-value-to_status={to_string(next_status)}
            >
              <%= Index.status_label(next_status) %>
            </button>
          <% end %>
        </div>

        <div class="relative">
          <button
            type="button"
            phx-click="open_card_action"
            phx-value-issue-id={@issue.id}
            class="text-text-quaternary hover:text-text-secondary transition-colors p-1 rounded hover:bg-white/[0.05]"
            title="Quick actions"
          >
            <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 5v.01M12 12v.01M12 19v.01M12 6a1 1 0 110-2 1 1 0 010 2zm0 7a1 1 0 110-2 1 1 0 010 2zm0 7a1 1 0 110-2 1 1 0 010 2z"/></svg>
          </button>

          <%= if @card_action_open == @issue.id do %>
            <.quick_action_menu issue={@issue} agents={@agents} />
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  attr :issue, :map, required: true
  attr :agents, :list, required: true

  defp quick_action_menu(assigns) do
    ~H"""
    <div class="absolute right-0 top-6 z-50 w-52 bg-surface border border-border rounded-md shadow-xl py-1">
      <button type="button" phx-click="start_edit_title" phx-value-issue-id={@issue.id} class="w-full text-left text-sm px-3 py-1.5 text-text-secondary hover:bg-white/[0.05] hover:text-text-primary transition-colors flex items-center gap-2">
        <svg class="w-3.5 h-3.5" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z"/></svg>
        Edit title
      </button>
      <button type="button" phx-click="open_add_comment" phx-value-issue-id={@issue.id} class="w-full text-left text-sm px-3 py-1.5 text-text-secondary hover:bg-white/[0.05] hover:text-text-primary transition-colors flex items-center gap-2">
        <svg class="w-3.5 h-3.5" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M7 8h10M7 12h4m1 8l-4-4H5a2 2 0 01-2-2V6a2 2 0 012-2h14a2 2 0 012 2v8a2 2 0 01-2 2h-3l-4 4z"/></svg>
        Add comment
      </button>

      <div class="border-t border-border my-1"></div>
      <div class="text-[10px] font-510 text-text-quaternary uppercase tracking-wider px-3 py-1">Priority</div>
      <%= for p <- [:high, :medium, :low] do %>
        <button type="button" phx-click="quick_priority" phx-value-issue-id={@issue.id} phx-value-priority={to_string(p)} class={"w-full text-left text-sm px-3 py-1 transition-colors flex items-center gap-2 " <> if(@issue.priority == p, do: "bg-white/[0.05] text-text-primary", else: "text-text-secondary hover:bg-white/[0.05] hover:text-text-primary")}>
          <span class={"w-2 h-2 rounded-full " <> if(p == :high, do: "bg-red-400", else: if(p == :medium, do: "bg-yellow-400", else: "bg-emerald-400"))}></span>
          <%= to_string(p) %>
        </button>
      <% end %>

      <div class="border-t border-border my-1"></div>
      <div class="text-[10px] font-510 text-text-quaternary uppercase tracking-wider px-3 py-1">Assign</div>
      <%= for agent <- @agents do %>
        <button type="button" phx-click="quick_assign" phx-value-issue-id={@issue.id} phx-value-agent-id={agent.id} class={"w-full text-left text-sm px-3 py-1 transition-colors " <> if(@issue.assignee && @issue.assignee.id == agent.id, do: "bg-white/[0.05] text-text-primary", else: "text-text-secondary hover:bg-white/[0.05] hover:text-text-primary")}>
          <%= agent.name %>
        </button>
      <% end %>
      <%= if @issue.assignee do %>
        <button type="button" phx-click="quick_unassign" phx-value-issue-id={@issue.id} class="w-full text-left text-sm px-3 py-1 text-text-quaternary hover:bg-white/[0.05] hover:text-text-secondary transition-colors italic">
          Unassign
        </button>
      <% end %>
    </div>
    """
  end
end
