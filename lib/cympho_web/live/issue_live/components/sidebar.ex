defmodule CymphoWeb.IssueLive.Show.Sidebar do
  @moduledoc """
  Stateless function component for the issue's right-rail metadata sidebar:

    * Status / Priority / Assignee inline-edit comboboxes
    * Agent execution controls (toggle, release, spawn)
    * GitHub PR field + PR quality + repair packet
    * Documents list
    * Creation footer

  Events (`combobox_status`, `combobox_priority`, `combobox_assignee`,
  `toggle_agent_panel`, `release_issue`, `spawn_agent`,
  `update_github_pr_number`, `check_github_pr_quality`,
  `queue_contract_nudge`, `clear_github_pr_number`) bubble to the
  parent LiveView.
  """
  use CymphoWeb, :html

  import CymphoWeb.IssueLive.Show.Helpers

  attr :issue, :map, required: true
  attr :all_agents, :list, default: []
  attr :orchestrator_enabled?, :boolean, default: false
  attr :show_agent_panel, :boolean, default: false
  attr :agents, :list, default: []
  attr :documents, :list, default: []

  def sidebar(assigns) do
    ~H"""
    <aside class="w-full lg:w-[280px] shrink-0 border-t lg:border-t-0 lg:border-l border-hairline bg-surface-1/40">
      <div class="p-4 lg:p-5 space-y-4">
        <div class="space-y-3">
          <div class="flex items-center justify-between gap-3">
            <span class="text-eyebrow text-ink-tertiary uppercase">Status</span>
            <.combobox
              id="issue-status-combobox"
              options={status_combobox_options(@issue.status)}
              selected={to_string(@issue.status)}
              on_change="combobox_status"
              searchable?={false}
              clearable?={false}
              align="right"
            />
          </div>
          <div class="flex items-center justify-between gap-3">
            <span class="text-eyebrow text-ink-tertiary uppercase">Priority</span>
            <.combobox
              id="issue-priority-combobox"
              options={priority_combobox_options()}
              selected={to_string(@issue.priority)}
              on_change="combobox_priority"
              searchable?={false}
              clearable?={false}
              align="right"
            />
          </div>
          <div class="flex items-center justify-between gap-3">
            <span class="text-eyebrow text-ink-tertiary uppercase">Assignee</span>
            <.combobox
              id="issue-assignee-combobox"
              options={assignee_combobox_options(@all_agents)}
              selected={@issue.assignee_id}
              on_change="combobox_assignee"
              placeholder="Unassigned"
              clearable?={true}
              align="right"
            />
          </div>
        </div>

        <hr class="border-hairline" />

        <div id="issue-agent-panel" class="space-y-2">
          <p :if={!@orchestrator_enabled?} class="text-caption text-ink-tertiary">
            Agent execution is disabled for review mode.
          </p>
          <div class="flex items-center gap-2">
            <.button
              type="button"
              phx-click="toggle_agent_panel"
              size="sm"
              variant="secondary"
              disabled={!@orchestrator_enabled?}
            >
              {(@show_agent_panel && "Hide") || "Start"} agent
            </.button>
            <.button
              :if={@issue.assignee_id}
              type="button"
              phx-click="release_issue"
              size="sm"
              variant="ghost"
            >
              Release
            </.button>
          </div>

          <div :if={@show_agent_panel} class="space-y-2">
            <p :if={Enum.empty?(@agents)} class="text-caption text-ink-tertiary">
              No idle agents available.
            </p>
            <form :if={!Enum.empty?(@agents)} phx-submit="spawn_agent" class="space-y-2">
              <select
                name="agent_id"
                required
                class="w-full bg-surface-1 border border-hairline rounded-md px-2.5 h-7 text-caption text-ink focus:outline-none focus:border-primary appearance-none"
              >
                <option value="">Choose an agent…</option>
                <option :for={agent <- @agents} value={agent.id}>
                  {agent.name} ({agent.role})
                </option>
              </select>
              <.button type="submit" size="sm">Start agent</.button>
            </form>
          </div>
        </div>

        <hr class="border-hairline" />

        <details
          id="issue-github-pr"
          class="group"
          open={@issue.github_pr_number not in [nil, 0] or @issue.github_pr_url not in [nil, ""]}
        >
          <summary class="flex items-center justify-between gap-2 cursor-pointer text-eyebrow text-ink-tertiary uppercase list-none">
            <span>GitHub PR</span>
            <.icon
              name="hero-chevron-down-mini"
              class="w-3.5 h-3.5 text-ink-tertiary transition-transform group-open:rotate-180"
            />
          </summary>
          <form phx-submit="update_github_pr_number" class="mt-2 space-y-2">
            <div class="flex items-center gap-1.5">
              <span class="text-caption text-ink-tertiary">#</span>
              <input
                type="text"
                inputmode="numeric"
                name="github_pr_number"
                value={@issue.github_pr_number}
                placeholder="123"
                class="w-20 bg-surface-1 border border-hairline rounded-md px-2 h-7 text-caption text-ink placeholder:text-ink-tertiary focus:outline-none focus:border-primary"
              />
              <.button type="submit" size="sm">Save</.button>
            </div>
            <p
              :if={
                @issue.project && @issue.project.repo_url in [nil, ""] &&
                  @issue.github_pr_url in [nil, ""]
              }
              class="text-caption text-ink-tertiary"
            >
              Set a repo URL on
              <.app_link
                navigate={~p"/projects/#{@issue.project.id}"}
                class="text-primary hover:underline"
              >
                the project
              </.app_link>
              to enable PR links.
            </p>
            <a
              :if={Cympho.Issues.Issue.pr_url(@issue, @issue.project)}
              href={Cympho.Issues.Issue.pr_url(@issue, @issue.project)}
              target="_blank"
              rel="noopener"
              class="inline-flex items-center gap-1.5 text-caption text-primary hover:underline truncate max-w-full"
            >
              <.icon name="hero-arrow-top-right-on-square-mini" class="w-3.5 h-3.5 shrink-0" />
              <span class="truncate">{Cympho.Issues.Issue.pr_url(@issue, @issue.project)}</span>
            </a>
            <div
              :if={pr_quality(@issue)}
              class={"rounded-md border px-2.5 py-2 text-caption #{pr_quality_status_class(pr_quality(@issue))}"}
            >
              <div class="flex items-center justify-between gap-2">
                <span class="font-590">{pr_quality(@issue)["status_label"] || "PR quality"}</span>
                <span
                  :if={pr_quality_checked_label(pr_quality(@issue))}
                  class="text-[10px] opacity-70"
                >
                  {pr_quality_checked_label(pr_quality(@issue))}
                </span>
              </div>
              <p class="mt-1 leading-4">{pr_quality(@issue)["summary"]}</p>
              <ul :if={pr_quality_gaps(pr_quality(@issue)) != []} class="mt-2 space-y-1">
                <li :for={gap <- pr_quality_gaps(pr_quality(@issue))} class="leading-4">
                  <span class="font-590">{gap["label"]}</span>: {gap["detail"]}
                </li>
              </ul>
            </div>
            <details
              :if={pr_quality(@issue) && pr_quality(@issue)["status"] == "attention"}
              class="rounded-md border border-amber-500/20 bg-amber-500/[0.04] px-2.5 py-2 text-caption text-amber-100"
            >
              <% repair_packet = pr_repair_packet(@issue) %>
              <summary class="cursor-pointer font-590 text-amber-100">
                PR repair packet
              </summary>
              <div class="mt-2 space-y-2 text-[11px] leading-4">
                <div>
                  <p class="uppercase tracking-[0.08em] text-amber-100/55">Expected branch</p>
                  <code class="mt-1 block rounded border border-amber-500/15 bg-black/25 px-2 py-1 text-amber-50">
                    {repair_packet.branch_name}
                  </code>
                </div>
                <div>
                  <p class="uppercase tracking-[0.08em] text-amber-100/55">Expected title</p>
                  <code class="mt-1 block rounded border border-amber-500/15 bg-black/25 px-2 py-1 text-amber-50">
                    {repair_packet.title}
                  </code>
                </div>
                <div>
                  <p class="uppercase tracking-[0.08em] text-amber-100/55">Missing fields</p>
                  <ul class="mt-1 space-y-0.5">
                    <li :for={field <- pr_repair_missing_fields(repair_packet)}>
                      - {field}
                    </li>
                  </ul>
                </div>
                <div>
                  <p class="uppercase tracking-[0.08em] text-amber-100/55">Suggested commands</p>
                  <pre class="mt-1 max-h-32 overflow-auto whitespace-pre-wrap rounded border border-amber-500/15 bg-black/25 px-2 py-1 font-mono text-[10px] text-amber-50">{pr_repair_commands(repair_packet)}</pre>
                </div>
                <details>
                  <summary class="cursor-pointer text-amber-100/80">PR body template</summary>
                  <pre class="mt-1 max-h-44 overflow-auto whitespace-pre-wrap rounded border border-amber-500/15 bg-black/25 px-2 py-1 font-mono text-[10px] text-amber-50">{repair_packet.body_template}</pre>
                </details>
              </div>
            </details>
            <button
              :if={Cympho.Issues.Issue.pr_url(@issue, @issue.project)}
              type="button"
              phx-click="check_github_pr_quality"
              class="text-caption text-ink-tertiary hover:text-ink-muted"
            >
              Check PR quality
            </button>
            <button
              :if={pr_quality(@issue) && pr_quality(@issue)["status"] == "attention"}
              type="button"
              phx-click="queue_contract_nudge"
              phx-value-contract="pr_quality"
              class="text-caption text-amber-200 hover:text-amber-100"
            >
              Nudge agent to fix PR
            </button>
            <button
              :if={@issue.github_pr_number not in [nil, 0] or @issue.github_pr_url not in [nil, ""]}
              type="button"
              phx-click="clear_github_pr_number"
              data-confirm="Clear the PR?"
              class="text-caption text-ink-tertiary hover:text-ink-muted"
            >
              Clear
            </button>
          </form>
        </details>

        <hr :if={!Enum.empty?(@documents)} class="border-hairline" />

        <div :if={!Enum.empty?(@documents)} class="space-y-2">
          <span class="text-eyebrow text-ink-tertiary uppercase">Documents</span>
          <ul class="space-y-1">
            <li :for={doc <- @documents} class="text-caption text-ink-muted truncate">
              {doc.title || doc.key}
            </li>
          </ul>
        </div>

        <hr class="border-hairline" />

        <div class="text-caption text-ink-tertiary">
          Created {Calendar.strftime(@issue.inserted_at, "%b %-d, %Y")}
        </div>
      </div>
    </aside>
    """
  end
end
