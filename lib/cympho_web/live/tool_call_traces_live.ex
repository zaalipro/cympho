defmodule CymphoWeb.ToolCallTracesLive.Index do
  use CymphoWeb, :live_view
  alias Cympho.ToolCallTraces
  alias Cympho.Agents

  @impl true
  def mount(_params, _session, socket) do
    company_id = socket.assigns[:current_company][:id]

    {:ok,
     socket
     |> assign(:page_title, "Tool Call Traces")
     |> assign(:company_id, company_id)
     |> assign(:traces, [])
     |> assign(:filters, %{
       tool_name: "",
       status: "",
       agent_id: "",
       issue_id: ""
     })
     |> assign(:agents, Agents.list_agents())
     |> assign(:statistics, nil)
     |> assign(:integrity_status, :unknown)
     |> assign(:selected_trace, nil)
     |> assign(:export_data_json, nil)
     |> assign(:export_data_csv, nil)
     |> load_traces()}
  end

  @impl true
  def handle_event("filter", %{"filter" => filter_params}, socket) do
    filters = %{
      tool_name: Map.get(filter_params, "tool_name", ""),
      status: Map.get(filter_params, "status", ""),
      agent_id: Map.get(filter_params, "agent_id", ""),
      issue_id: Map.get(filter_params, "issue_id", "")
    }

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:selected_trace, nil)
     |> load_traces()}
  end

  @impl true
  def handle_event("clear_filters", _params, socket) do
    {:noreply,
     socket
     |> assign(:filters, %{
       tool_name: "",
       status: "",
       agent_id: "",
       issue_id: ""
     })
     |> assign(:selected_trace, nil)
     |> load_traces()}
  end

  @impl true
  def handle_event("select_trace", %{"id" => id}, socket) do
    case ToolCallTraces.get_tool_call_trace(id) do
      {:ok, trace} ->
        trace = case trace.agent_id do
          nil -> trace
          agent_id ->
            case Cympho.Agents.get_agent(agent_id) do
              {:ok, agent} -> %{trace | agent: agent}
              {:error, _} -> trace
            end
        end
        {:noreply, assign(socket, :selected_trace, trace)}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Trace not found")}
    end
  end

  @impl true
  def handle_event("close_trace_details", _params, socket) do
    {:noreply, assign(socket, :selected_trace, nil)}
  end

  @impl true
  def handle_event("verify_integrity", _params, socket) do
    company_id = socket.assigns.company_id

    integrity_status = ToolCallTraces.verify_chain_integrity(company_id)

    {:noreply, assign(socket, :integrity_status, integrity_status)}
  end

  @impl true
  def handle_event("export_json", _params, socket) do
    traces = socket.assigns.traces

    json_data =
      traces
      |> Enum.map(fn trace ->
        %{
          id: trace.id,
          sequence_number: trace.sequence_number,
          trace_type: trace.trace_type,
          tool_name: trace.tool_name,
          tool_arguments: trace.tool_arguments,
          tool_result: trace.tool_result,
          error_message: trace.error_message,
          status: trace.status,
          occurred_at: trace.occurred_at,
          content_hash: trace.content_hash,
          prev_hash: trace.prev_hash,
          chain_hash: trace.chain_hash,
          agent_id: trace.agent_id,
          issue_id: trace.issue_id
        }
      end)
      |> Jason.encode!(pretty: true)

    {:noreply,
     socket
     |> assign(:export_data_json, json_data)
     |> put_flash(:info, "Exported #{length(traces)} traces as JSON")}
  end

  @impl true
  def handle_event("export_csv", _params, socket) do
    traces = socket.assigns.traces

    csv_headers = ["Sequence", "Type", "Tool", "Status", "Occurred At", "Agent ID", "Issue ID"]

    csv_rows =
      traces
      |> Enum.map(fn trace ->
        [
          to_string(trace.sequence_number),
          trace.trace_type,
          trace.tool_name,
          trace.status,
          DateTime.to_string(trace.occurred_at),
          trace.agent_id || "",
          trace.issue_id || ""
        ]
      end)

    csv_content = [csv_headers | csv_rows]
    |> Enum.map(&Enum.join(&1, ","))
    |> Enum.join("\n")

    {:noreply,
     socket
     |> assign(:export_data_csv, csv_content)
     |> put_flash(:info, "Exported #{length(traces)} traces as CSV")}
  end

  defp load_traces(socket) do
    company_id = socket.assigns.company_id
    filters = socket.assigns.filters

    opts = [company_id: company_id]

    opts =
      if filters.tool_name != "" do
        Keyword.put(opts, :tool_name, filters.tool_name)
      else
        opts
      end

    opts =
      if filters.status != "" do
        Keyword.put(opts, :status, filters.status)
      else
        opts
      end

    opts =
      if filters.agent_id != "" do
        Keyword.put(opts, :agent_id, filters.agent_id)
      else
        opts
      end

    opts =
      if filters.issue_id != "" do
        Keyword.put(opts, :issue_id, filters.issue_id)
      else
        opts
      end

    traces = ToolCallTraces.list_tool_call_traces(opts)
    |> Enum.map(fn trace ->
      case trace.agent_id do
        nil -> trace
        agent_id ->
          case Cympho.Agents.get_agent(agent_id) do
            {:ok, agent} -> %{trace | agent: agent}
            {:error, _} -> trace
          end
      end
    end)

    statistics = ToolCallTraces.get_statistics(company_id)

    socket
    |> assign(:traces, traces)
    |> assign(:statistics, statistics)
    |> assign(:export_data_json, nil)
    |> assign(:export_data_csv, nil)
  end

  def status_color("success"), do: "text-green-400"
  def status_color("error"), do: "text-red-400"
  def status_color("pending"), do: "text-yellow-400"
  def status_color("timeout"), do: "text-orange-400"
  def status_color(_), do: "text-gray-400"

  def status_icon("success"), do: "✓"
  def status_icon("error"), do: "✗"
  def status_icon("pending"), do: "⏳"
  def status_icon("timeout"), do: "⏱"
  def status_icon(_), do: "?"

  def integrity_status_color(:ok), do: "text-green-400"
  def integrity_status_color(:unknown), do: "text-gray-400"
  def integrity_status_color({:error, _}), do: "text-red-400"

  def integrity_status_label(:ok), do: "Chain integrity verified"
  def integrity_status_label(:unknown), do: "Integrity not checked"
  def integrity_status_label({:error, :chain_broken, _, _}), do: "Chain integrity broken!"
  def integrity_status_label({:error, _}), do: "Integrity check failed"

  def format_datetime(datetime) do
    DateTime.to_string(datetime)
  end

  def format_json(map) when is_map(map) do
    map
    |> Jason.encode!(pretty: true)
  end

  def format_json(_), do: ""

  def render(assigns) do
    ~H"""
    <div class="container mx-auto px-4 py-8">
      <div class="mb-6">
        <h1 class="text-2xl font-bold text-text-primary mb-2">Tool Call Traces</h1>
        <p class="text-text-secondary">Browse and verify immutable tool-call chains</p>
      </div>

      <div class="mb-6 flex flex-wrap gap-4 items-center justify-between">
        <div class="flex gap-2">
          <button
            type="button"
            class="px-4 py-2 bg-brand hover:bg-brand/90 text-white rounded-lg transition-colors"
            phx-click="verify_integrity"
          >
            Verify Integrity
          </button>

          <button
            :if={!@export_data_json}
            type="button"
            class="px-4 py-2 bg-surface border border-border hover:border-brand/50 text-text-primary rounded-lg transition-colors"
            phx-click="export_json"
          >
            Export JSON
          </button>

          <a
            :if={@export_data_json}
            download={"tool-traces-#{Date.utc_today()}.json"}
            href={"data:application/json;charset=utf-8,#{URI.encode(@export_data_json)}"}
            class="px-4 py-2 bg-green-600 hover:bg-green-700 text-white rounded-lg transition-colors inline-flex items-center gap-2"
          >
            <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 16v1a3 3 0 003 3h10a3 3 0 003-3v-1m-4-8l-4-4m0 0L8 8m4-4v12" />
            </svg>
            Download JSON
          </a>

          <button
            :if={!@export_data_csv}
            type="button"
            class="px-4 py-2 bg-surface border border-border hover:border-brand/50 text-text-primary rounded-lg transition-colors"
            phx-click="export_csv"
          >
            Export CSV
          </button>

          <a
            :if={@export_data_csv}
            download={"tool-traces-#{Date.utc_today()}.csv"}
            href={"data:text/csv;charset=utf-8,#{URI.encode(@export_data_csv)}"}
            class="px-4 py-2 bg-green-600 hover:bg-green-700 text-white rounded-lg transition-colors inline-flex items-center gap-2"
          >
            <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 16v1a3 3 0 003 3h10a3 3 0 003-3v-1m-4-8l-4-4m0 0L8 8m4-4v12" />
            </svg>
            Download CSV
          </a>
        </div>

        <div class={"text-sm font-medium " <> integrity_status_color(@integrity_status)}>
          <%= integrity_status_label(@integrity_status) %>
        </div>
      </div>

      <form phx-submit="filter" class="mb-6 bg-surface border border-border rounded-lg p-4">
        <div class="grid grid-cols-1 md:grid-cols-4 gap-4 mb-4">
          <div>
            <label class="block text-sm font-medium text-text-secondary mb-1">Tool Name</label>
            <input
              type="text"
              name="filter[tool_name]"
              value={@filters.tool_name}
              placeholder="Filter by tool name..."
              class="w-full px-3 py-2 bg-black/[0.2] border border-border rounded-lg text-text-primary placeholder-text-secondary focus:outline-none focus:border-brand/50"
            />
          </div>

          <div>
            <label class="block text-sm font-medium text-text-secondary mb-1">Status</label>
            <select
              name="filter[status]"
              class="w-full px-3 py-2 bg-black/[0.2] border border-border rounded-lg text-text-primary focus:outline-none focus:border-brand/50"
            >
              <option value="">All Statuses</option>
              <option value="success" selected={@filters.status == "success"}>Success</option>
              <option value="error" selected={@filters.status == "error"}>Error</option>
              <option value="pending" selected={@filters.status == "pending"}>Pending</option>
              <option value="timeout" selected={@filters.status == "timeout"}>Timeout</option>
            </select>
          </div>

          <div>
            <label class="block text-sm font-medium text-text-secondary mb-1">Agent</label>
            <select
              name="filter[agent_id]"
              class="w-full px-3 py-2 bg-black/[0.2] border border-border rounded-lg text-text-primary focus:outline-none focus:border-brand/50"
            >
              <option value="">All Agents</option>
              <%= for agent <- @agents do %>
                <option value={agent.id} selected={@filters.agent_id == agent.id}><%= agent.name %></option>
              <% end %>
            </select>
          </div>

          <div>
            <label class="block text-sm font-medium text-text-secondary mb-1">Issue ID</label>
            <input
              type="text"
              name="filter[issue_id]"
              value={@filters.issue_id}
              placeholder="Filter by issue ID..."
              class="w-full px-3 py-2 bg-black/[0.2] border border-border rounded-lg text-text-primary placeholder-text-secondary focus:outline-none focus:border-brand/50"
            />
          </div>
        </div>

        <div class="flex gap-2">
          <button
            type="submit"
            class="px-4 py-2 bg-brand hover:bg-brand/90 text-white rounded-lg transition-colors"
          >
            Apply Filters
          </button>

          <button
            type="button"
            class="px-4 py-2 bg-surface border border-border hover:border-brand/50 text-text-primary rounded-lg transition-colors"
            phx-click="clear_filters"
          >
            Clear Filters
          </button>
        </div>
      </form>

      <%= if @statistics do %>
        <div class="mb-6 grid grid-cols-1 md:grid-cols-4 gap-4">
          <div class="bg-surface border border-border rounded-lg p-4">
            <div class="text-text-secondary text-sm mb-1">Total Calls</div>
            <div class="text-2xl font-bold text-text-primary"><%= @statistics.total_calls %></div>
          </div>

          <div class="bg-surface border border-border rounded-lg p-4">
            <div class="text-text-secondary text-sm mb-1">Success</div>
            <div class="text-2xl font-bold text-green-400"><%= @statistics.success_calls %></div>
          </div>

          <div class="bg-surface border border-border rounded-lg p-4">
            <div class="text-text-secondary text-sm mb-1">Errors</div>
            <div class="text-2xl font-bold text-red-400"><%= @statistics.error_calls %></div>
          </div>

          <div class="bg-surface border border-border rounded-lg p-4">
            <div class="text-text-secondary text-sm mb-1">Pending</div>
            <div class="text-2xl font-bold text-yellow-400"><%= @statistics.pending_calls %></div>
          </div>
        </div>
      <% end %>

      <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
        <div class="lg:col-span-2">
          <div class="bg-surface border border-border rounded-lg overflow-hidden">
            <div class="px-4 py-3 border-b border-border">
              <h2 class="text-lg font-semibold text-text-primary">Traces</h2>
            </div>

            <%= if @traces == [] do %>
              <div class="p-8 text-center text-text-secondary">
                <p class="mb-2">No traces found</p>
                <p class="text-sm">Tool call traces will appear here as agents use tools</p>
              </div>
            <% else %>
              <div class="overflow-x-auto">
                <table class="w-full">
                  <thead class="bg-white/[0.02]">
                    <tr>
                      <th class="px-4 py-3 text-left text-xs font-medium text-text-secondary uppercase tracking-wider">Seq</th>
                      <th class="px-4 py-3 text-left text-xs font-medium text-text-secondary uppercase tracking-wider">Tool</th>
                      <th class="px-4 py-3 text-left text-xs font-medium text-text-secondary uppercase tracking-wider">Actor</th>
                      <th class="px-4 py-3 text-left text-xs font-medium text-text-secondary uppercase tracking-wider">Status</th>
                      <th class="px-4 py-3 text-left text-xs font-medium text-text-secondary uppercase tracking-wider">Time</th>
                      <th class="px-4 py-3 text-left text-xs font-medium text-text-secondary uppercase tracking-wider">Chain Hash</th>
                    </tr>
                  </thead>
                  <tbody class="divide-y divide-border">
                    <%= for trace <- @traces do %>
                      <tr
                        class={if @selected_trace && @selected_trace.id == trace.id, do: "bg-brand/10 cursor-pointer", else: "hover:bg-white/[0.02] cursor-pointer"}
                        phx-click="select_trace"
                        phx-value-id={trace.id}
                      >
                        <td class="px-4 py-3 whitespace-nowrap text-sm text-text-primary">
                          <%= trace.sequence_number %>
                        </td>
                        <td class="px-4 py-3 text-sm text-text-primary">
                          <div class="font-medium"><%= trace.tool_name %></div>
                          <div class="text-xs text-text-secondary"><%= trace.trace_type %></div>
                        </td>
                        <td class="px-4 py-3 text-sm text-text-secondary">
                          <div class="flex items-center gap-1">
                            <span class="text-xs capitalize"><%= trace.actor_type %></span>
                            <%= if trace.actor_type == "agent" && trace.agent do %>
                              <span class="text-xs text-text-tertiary">(<%= trace.agent.name %>)</span>
                            <% end %>
                          </div>
                        </td>
                        <td class={"px-4 py-3 whitespace-nowrap text-sm " <> status_color(trace.status)}>
                          <span class="inline-flex items-center">
                            <span class="mr-1"><%= status_icon(trace.status) %></span>
                            <%= String.capitalize(trace.status) %>
                          </span>
                        </td>
                        <td class="px-4 py-3 whitespace-nowrap text-sm text-text-secondary">
                          <%= format_datetime(trace.occurred_at) %>
                        </td>
                        <td class="px-4 py-3 text-xs text-text-secondary font-mono">
                          <%= String.slice(trace.chain_hash, 0..7) %>...
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            <% end %>
          </div>
        </div>

        <%= if @selected_trace do %>
          <div class="lg:col-span-1">
            <div class="bg-surface border border-border rounded-lg sticky top-4">
              <div class="px-4 py-3 border-b border-border flex items-center justify-between">
                <h2 class="text-lg font-semibold text-text-primary">Trace Details</h2>
                <button
                  type="button"
                  class="p-1 hover:bg-white/[0.1] rounded"
                  phx-click="close_trace_details"
                >
                  <svg class="w-5 h-5 text-text-secondary" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
                  </svg>
                </button>
              </div>

              <div class="p-4 space-y-4">
                <div>
                  <div class="text-xs text-text-secondary mb-1">Sequence Number</div>
                  <div class="text-sm font-mono text-text-primary"><%= @selected_trace.sequence_number %></div>
                </div>

                <div>
                  <div class="text-xs text-text-secondary mb-1">Tool Name</div>
                  <div class="text-sm font-medium text-text-primary"><%= @selected_trace.tool_name %></div>
                </div>

                <div>
                  <div class="text-xs text-text-secondary mb-1">Trace Type</div>
                  <div class="text-sm text-text-primary"><%= @selected_trace.trace_type %></div>
                </div>

                <div>
                  <div class="text-xs text-text-secondary mb-1">Status</div>
                  <div class={"text-sm font-medium " <> status_color(@selected_trace.status)}>
                    <span class="inline-flex items-center">
                      <span class="mr-1"><%= status_icon(@selected_trace.status) %></span>
                      <%= String.capitalize(@selected_trace.status) %>
                    </span>
                  </div>
                </div>

                <div>
                  <div class="text-xs text-text-secondary mb-1">Occurred At</div>
                  <div class="text-sm text-text-primary"><%= format_datetime(@selected_trace.occurred_at) %></div>
                </div>

                <div>
                  <div class="text-xs text-text-secondary mb-1">Content Hash</div>
                  <div class="text-xs font-mono text-text-secondary break-all"><%= @selected_trace.content_hash %></div>
                </div>

                <div>
                  <div class="text-xs text-text-secondary mb-1">Previous Hash</div>
                  <div class="text-xs font-mono text-text-secondary break-all">
                    <%= @selected_trace.prev_hash || "None (genesis trace)" %>
                  </div>
                </div>

                <div>
                  <div class="text-xs text-text-secondary mb-1">Chain Hash</div>
                  <div class="text-xs font-mono text-text-secondary break-all"><%= @selected_trace.chain_hash %></div>
                </div>

                <div>
                  <div class="text-xs text-text-secondary mb-1">Actor Type</div>
                  <div class="text-sm text-text-primary capitalize"><%= @selected_trace.actor_type %></div>
                </div>

                <div>
                  <div class="text-xs text-text-secondary mb-1">Actor ID</div>
                  <div class="text-sm font-mono text-text-primary"><%= @selected_trace.actor_id %></div>
                </div>

                <%= if @selected_trace.actor_type == "agent" && @selected_trace.agent do %>
                  <div>
                    <div class="text-xs text-text-secondary mb-1">Agent Name</div>
                    <div class="text-sm text-text-primary"><%= @selected_trace.agent.name %></div>
                  </div>
                <% end %>

                <%= if @selected_trace.agent_id do %>
                  <div>
                    <div class="text-xs text-text-secondary mb-1">Original Agent ID</div>
                    <div class="text-sm font-mono text-text-primary"><%= @selected_trace.agent_id %></div>
                  </div>
                <% end %>

                <%= if @selected_trace.issue_id do %>
                  <div>
                    <div class="text-xs text-text-secondary mb-1">Issue ID</div>
                    <div class="text-sm font-mono text-text-primary"><%= @selected_trace.issue_id %></div>
                  </div>
                <% end %>

                <%= if @selected_trace.tool_arguments != %{} do %>
                  <div>
                    <div class="text-xs text-text-secondary mb-2">Tool Arguments</div>
                    <pre class="bg-black/[0.3] rounded p-3 text-xs text-text-secondary overflow-x-auto"><%= format_json(@selected_trace.tool_arguments) %></pre>
                  </div>
                <% end %>

                <%= if @selected_trace.tool_result do %>
                  <div>
                    <div class="text-xs text-text-secondary mb-2">Tool Result</div>
                    <pre class="bg-black/[0.3] rounded p-3 text-xs text-text-secondary overflow-x-auto max-h-40 overflow-y-auto"><%= @selected_trace.tool_result %></pre>
                  </div>
                <% end %>

                <%= if @selected_trace.error_message do %>
                  <div>
                    <div class="text-xs text-text-secondary mb-2">Error Message</div>
                    <pre class="bg-red-500/10 border border-red-500/30 rounded p-3 text-xs text-red-400 overflow-x-auto"><%= @selected_trace.error_message %></pre>
                  </div>
                <% end %>
              </div>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end

