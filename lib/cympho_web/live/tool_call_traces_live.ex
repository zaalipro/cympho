defmodule CymphoWeb.ToolCallTracesLive.Index do
  use CymphoWeb, :live_view
  alias Cympho.ToolCallTraces
  alias Cympho.Agents
  alias Cympho.RuntimeOperations

  @impl true
  def mount(_params, _session, socket) do
    company_id = socket.assigns[:current_company][:id]

    socket =
      socket
      |> assign(:page_title, "Tool Call Traces")
      |> assign(:company_id, company_id)
      |> assign(:infinite_scroll, %{})
      |> assign(:filters, %{
        tool_name: "",
        status: "",
        agent_id: "",
        issue_id: "",
        run_id: ""
      })
      |> assign(:agents, list_agents_scoped(company_id))
      |> assign(:integrity_status, :unknown)
      |> assign(:selected_trace, nil)
      |> assign(:export_data_json, nil)
      |> assign(:export_data_csv, nil)
      |> load_statistics()

    {:ok, init_stream(socket, :traces, &fetch_traces(socket, &1))}
  end

  @impl true
  def handle_event("filter", %{"filter" => filter_params}, socket) do
    filters = %{
      tool_name: Map.get(filter_params, "tool_name", ""),
      status: Map.get(filter_params, "status", ""),
      agent_id: Map.get(filter_params, "agent_id", ""),
      issue_id: Map.get(filter_params, "issue_id", ""),
      run_id: Map.get(filter_params, "run_id", "")
    }

    socket =
      socket
      |> assign(:filters, filters)
      |> assign(:selected_trace, nil)
      |> assign(:export_data_json, nil)
      |> assign(:export_data_csv, nil)
      |> load_statistics()

    {:noreply, reset_stream(socket, :traces, &fetch_traces(socket, &1))}
  end

  @impl true
  def handle_event("clear_filters", _params, socket) do
    socket =
      socket
      |> assign(:filters, %{tool_name: "", status: "", agent_id: "", issue_id: "", run_id: ""})
      |> assign(:selected_trace, nil)
      |> assign(:export_data_json, nil)
      |> assign(:export_data_csv, nil)
      |> load_statistics()

    {:noreply, reset_stream(socket, :traces, &fetch_traces(socket, &1))}
  end

  @impl true
  def handle_event("next-page", _params, socket) do
    {:reply, %{}, load_next(socket, :traces, &fetch_traces(socket, &1))}
  end

  @impl true
  def handle_event("select_trace", %{"id" => id}, socket) do
    case get_scoped_trace(socket.assigns.company_id, id) do
      {:ok, trace} ->
        trace = preload_scoped_agent(trace, socket.assigns.company_id)
        previous = socket.assigns.selected_trace

        socket =
          socket
          |> assign(:selected_trace, trace)
          |> stream_insert(:traces, trace)

        # Re-render the previously selected row so its highlight clears — streams
        # don't re-render existing items on an unrelated assign change.
        socket = if previous, do: stream_insert(socket, :traces, previous), else: socket
        {:noreply, socket}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Trace not found")}
    end
  end

  @impl true
  def handle_event("close_trace_details", _params, socket) do
    previous = socket.assigns.selected_trace
    socket = assign(socket, :selected_trace, nil)
    socket = if previous, do: stream_insert(socket, :traces, previous), else: socket
    {:noreply, socket}
  end

  @impl true
  def handle_event("verify_integrity", _params, socket) do
    company_id = socket.assigns.company_id

    integrity_status = ToolCallTraces.verify_chain_integrity(company_id)

    {:noreply,
     socket
     |> assign(:integrity_status, integrity_status)
     |> assign_trace_command()}
  end

  @impl true
  def handle_event("export_json", _params, socket) do
    traces = export_traces(socket)

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
          issue_id: trace.issue_id,
          run_id: trace.run_id
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
    traces = export_traces(socket)

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

    csv_content =
      [csv_headers | csv_rows]
      |> Enum.map(&Enum.join(&1, ","))
      |> Enum.join("\n")

    {:noreply,
     socket
     |> assign(:export_data_csv, csv_content)
     |> put_flash(:info, "Exported #{length(traces)} traces as CSV")}
  end

  defp list_agents_scoped(nil), do: []
  defp list_agents_scoped(company_id), do: Agents.list_agents_by_company(company_id)

  defp fetch_traces(socket, cursor) do
    company_id = socket.assigns.company_id

    page =
      ([company_id: company_id, after: cursor] ++ filter_opts(socket))
      |> ToolCallTraces.list_tool_call_traces_page()

    %{page | entries: Enum.map(page.entries, &preload_scoped_agent(&1, company_id))}
  end

  # Export operates on the full filtered set, not just the loaded page.
  defp export_traces(socket) do
    ([company_id: socket.assigns.company_id] ++ filter_opts(socket))
    |> ToolCallTraces.list_tool_call_traces()
  end

  defp filter_opts(socket) do
    f = socket.assigns.filters

    []
    |> maybe_put(:tool_name, f.tool_name)
    |> maybe_put(:status, f.status)
    |> maybe_put(:agent_id, f.agent_id)
    |> maybe_put(:issue_id, f.issue_id)
    |> maybe_put(:run_id, Map.get(f, :run_id, ""))
  end

  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp filters_active?(filters) do
    Enum.any?(filters, fn {_key, value} -> value not in [nil, ""] end)
  end

  defp load_statistics(socket) do
    statistics = ToolCallTraces.get_statistics(socket.assigns.company_id)

    socket
    |> assign(:statistics, statistics)
    |> assign_trace_command()
  end

  defp get_scoped_trace(company_id, id) do
    case ToolCallTraces.get_tool_call_trace(id) do
      {:ok, %{company_id: ^company_id} = trace} -> {:ok, trace}
      {:ok, _trace} -> {:error, :not_found}
      {:error, _} -> {:error, :not_found}
    end
  end

  defp preload_scoped_agent(%{agent_id: nil} = trace, _company_id), do: trace

  defp preload_scoped_agent(trace, company_id) do
    case Agents.get_company_agent(company_id, trace.agent_id) do
      {:ok, agent} -> %{trace | agent: agent}
      {:error, _} -> trace
    end
  end

  def status_color("success"), do: "text-green-400"
  def status_color("error"), do: "text-brand"
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
  def integrity_status_color({:error, _}), do: "text-brand"

  def integrity_status_color(status)
      when is_tuple(status) and elem(status, 0) == :error,
      do: "text-brand"

  def integrity_status_label(:ok), do: "Chain integrity verified"
  def integrity_status_label(:unknown), do: "Integrity not checked"

  def integrity_status_label({:error, :content_hash_mismatch, sequence}),
    do: "Content hash mismatch at sequence #{sequence}"

  def integrity_status_label({:error, :chain_broken, _, _}), do: "Chain integrity broken!"
  def integrity_status_label({:error, _}), do: "Integrity check failed"

  def integrity_status_label(status) when is_tuple(status) and elem(status, 0) == :error,
    do: "Integrity check failed"

  defp assign_trace_command(socket) do
    assign(socket, :trace_command, build_trace_command(socket.assigns))
  end

  defp build_trace_command(%{integrity_status: integrity_status, statistics: statistics})
       when is_tuple(integrity_status) and elem(integrity_status, 0) == :error do
    %{
      tone: :critical,
      badge: "Chain broken",
      title: "Stop trusting trace exports until integrity is repaired",
      summary: integrity_failure_summary(integrity_status),
      action_label: "Verify again",
      action_event: "verify_integrity",
      action_path: nil,
      metrics: trace_command_metrics(statistics)
    }
  end

  defp build_trace_command(%{statistics: %{error_calls: errors} = statistics}) when errors > 0 do
    %{
      tone: :critical,
      badge: "Tool failures",
      title: "Inspect failed tool calls",
      summary:
        "#{pluralize(errors, "tool call")} ended in error. Filter the trace list, open the failing row, and compare arguments to the tool result.",
      action_label: "Filter failures",
      action_event: nil,
      action_path: "#trace-filters",
      metrics: trace_command_metrics(statistics)
    }
  end

  defp build_trace_command(%{statistics: %{pending_calls: pending} = statistics})
       when pending > 0 do
    %{
      tone: :warning,
      badge: "Pending tools",
      title: "Check unfinished tool calls",
      summary:
        "#{pluralize(pending, "tool call")} are still pending or timed out. Filter pending traces before relaunching the same issue.",
      action_label: "Review pending",
      action_event: nil,
      action_path: "#trace-filters",
      metrics: trace_command_metrics(statistics)
    }
  end

  defp build_trace_command(%{statistics: %{total_calls: 0} = statistics}) do
    %{
      tone: :attention,
      badge: "No traces yet",
      title: "Launch runtime to capture tool evidence",
      summary: "Nothing recorded yet. Tool calls appear here as soon as agents start working.",
      action_label: "Open operations",
      action_event: nil,
      action_path: "/operations#runtime-launch-checklist",
      metrics: trace_command_metrics(statistics)
    }
  end

  defp build_trace_command(%{integrity_status: :unknown, statistics: statistics}) do
    %{
      tone: :attention,
      badge: "Integrity unchecked",
      title: "Verify the audit chain",
      summary:
        "Trace capture is available, but the chain has not been checked in this session. Verify before exporting evidence.",
      action_label: "Verify integrity",
      action_event: "verify_integrity",
      action_path: nil,
      metrics: trace_command_metrics(statistics)
    }
  end

  defp build_trace_command(%{statistics: statistics}) do
    %{
      tone: :ready,
      badge: "Trace chain healthy",
      title: "Tool evidence is audit-ready",
      summary:
        "All current tool calls are successful and the trace chain is ready for export or issue-level review.",
      action_label: "Review traces",
      action_event: nil,
      action_path: "#traces-table",
      metrics: trace_command_metrics(statistics)
    }
  end

  defp integrity_failure_summary({:error, :content_hash_mismatch, sequence}) do
    "Trace sequence #{sequence} has a stale or tampered content hash. Inspect that row before using exports for audit or governance."
  end

  defp integrity_failure_summary({:error, :chain_broken, from_sequence, to_sequence}) do
    "Trace chain link #{from_sequence} -> #{to_sequence} failed verification. Inspect the affected sequence before using exports for audit or governance."
  end

  defp integrity_failure_summary(_status) do
    "The immutable trace chain failed verification. Inspect the affected sequence before using exports for audit or governance."
  end

  defp trace_command_metrics(statistics) do
    [
      %{label: "Total", value: to_string(statistics.total_calls)},
      %{label: "Success", value: to_string(statistics.success_calls)},
      %{label: "Errors", value: to_string(statistics.error_calls)},
      %{label: "Pending", value: to_string(statistics.pending_calls)}
    ]
  end

  defp trace_command_badge_class(:critical),
    do: "border-red-500/25 bg-red-500/10 text-red-300"

  defp trace_command_badge_class(:warning),
    do: "border-amber-500/25 bg-amber-500/10 text-amber-200"

  defp trace_command_badge_class(:attention),
    do: "border-brand/25 bg-brand/10 text-brand"

  defp trace_command_badge_class(:ready),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"

  defp trace_command_action_class(:critical),
    do: "border-red-500/25 bg-red-500/10 text-red-200 hover:bg-red-500/15"

  defp trace_command_action_class(:warning),
    do: "border-amber-500/25 bg-amber-500/10 text-amber-100 hover:bg-amber-500/15"

  defp trace_command_action_class(:attention),
    do: "border-brand/25 bg-brand/10 text-brand hover:bg-brand/15"

  defp trace_command_action_class(:ready),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-200 hover:bg-emerald-500/15"

  defp trace_recovery(%{status: status} = trace) when status in ["error", "timeout", "pending"] do
    %{
      title: trace_recovery_title(status),
      summary: trace_recovery_summary(status, trace),
      issue_path: trace.issue_id && "/issues/#{trace.issue_id}",
      operations_path: "/operations#runtime-failures",
      focused_command:
        trace.issue_id && RuntimeOperations.focused_runtime_launch_command(trace.issue_id)
    }
  end

  defp trace_recovery(_trace), do: nil

  defp trace_recovery_title("pending"), do: "Recovery path"
  defp trace_recovery_title("timeout"), do: "Timeout recovery"
  defp trace_recovery_title(_status), do: "Failure recovery"

  defp trace_recovery_summary("pending", _trace) do
    "This tool call has not resolved yet. Inspect the linked issue before relaunching so duplicate work is not started."
  end

  defp trace_recovery_summary("timeout", _trace) do
    "The tool call timed out. Inspect issue context, then use a focused relaunch if the issue still needs runtime work."
  end

  defp trace_recovery_summary(_status, trace) do
    tool = trace.tool_name || "tool"

    "The #{tool} call failed. Compare arguments and result below, then relaunch the linked issue only after the blocker is fixed."
  end

  defp pluralize(1, singular), do: "1 #{singular}"
  defp pluralize(count, singular), do: "#{count} #{singular}s"

  def format_datetime(datetime) do
    DateTime.to_string(datetime)
  end

  def format_json(map) when is_map(map) do
    map
    |> Jason.encode!(pretty: true)
  end

  def format_json(_), do: ""

  @impl true
  def render(assigns) do
    ~H"""
    <div class="ember-aurora p-6 lg:p-8 w-full min-w-0" data-ui-complex-page>
      <div class="relative z-[1] mx-auto max-w-6xl">
        <.header>
          <div class="min-w-0">
            <span class="ember-eyebrow">Runtime evidence</span>
            <h1 class="ember-ink mt-4 font-serif text-[clamp(26px,4vw,40px)] font-510 leading-[1.08] tracking-[-0.02em]">
              Tool Call Traces
            </h1>
            <p class="mt-2 max-w-2xl text-[15px] leading-6 text-text-tertiary">
              Browse and verify immutable tool-call chains.
            </p>
          </div>
        </.header>

        <section
          id="trace-command"
          data-testid="trace-command"
          class="mb-6 ember-glass overflow-hidden"
        >
          <div class="border-b border-white/10 bg-gradient-to-b from-surface-2/50 to-transparent px-5 py-4">
            <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
              <div class="min-w-0">
                <div class="flex flex-wrap items-center gap-2">
                  <p class="font-serif text-[13px] font-510 italic tracking-[0.02em] text-brand/90">
                    Trace command
                  </p>
                  <span class={[
                    "rounded-full border px-2 py-0.5 text-[11px] font-510",
                    trace_command_badge_class(@trace_command.tone)
                  ]}>
                    {@trace_command.badge}
                  </span>
                </div>
                <h2 class="mt-2 text-lg font-590 tracking-tight text-text-primary">
                  {@trace_command.title}
                </h2>
                <p class="mt-1 max-w-2xl text-sm leading-5 text-text-tertiary">
                  {@trace_command.summary}
                </p>
              </div>

              <button
                :if={@trace_command.action_event}
                type="button"
                phx-click={@trace_command.action_event}
                class={[
                  "inline-flex shrink-0 items-center justify-center gap-2 rounded-lg border px-3 py-2 text-sm font-510 transition-colors",
                  trace_command_action_class(@trace_command.tone)
                ]}
              >
                <span class="hero-shield-check-mini h-4 w-4"></span>
                {@trace_command.action_label}
              </button>

              <a
                :if={@trace_command.action_path}
                href={@trace_command.action_path}
                class={[
                  "inline-flex shrink-0 items-center justify-center gap-2 rounded-lg border px-3 py-2 text-sm font-510 transition-colors",
                  trace_command_action_class(@trace_command.tone)
                ]}
              >
                <span class="hero-arrow-right-mini h-4 w-4"></span>
                {@trace_command.action_label}
              </a>
            </div>
          </div>

          <div class="grid grid-cols-2 gap-px bg-border sm:grid-cols-4">
            <div :for={metric <- @trace_command.metrics} class="bg-surface px-4 py-3">
              <p class="text-[10px] font-590 uppercase tracking-[0.12em] text-text-quaternary">
                {metric.label}
              </p>
              <p class="mt-1 font-mono text-sm font-590 text-text-primary">{metric.value}</p>
            </div>
          </div>
        </section>

        <%!-- Audit tooling: the four export buttons are download icons that keep
             their label as the accessible name, and the chain check already has
             a primary button in the command strip above. --%>
        <div class="ui-advanced-only mb-6 flex flex-wrap gap-4 items-center justify-between">
          <div class="flex gap-2">
            <button
              type="button"
              class="cta-glow rounded-button bg-brand px-4 py-2 min-h-[40px] text-sm font-510 text-on-primary transition-colors hover:bg-accent"
              phx-click="verify_integrity"
            >
              Verify Integrity
            </button>

            <button
              :if={!@export_data_json}
              type="button"
              title="Export JSON"
              aria-label="Export JSON"
              class="inline-flex items-center justify-center gap-1.5 rounded-lg border border-border bg-button px-3 py-2 min-h-[40px] text-sm font-510 text-text-secondary transition-colors hover:bg-button-hover hover:text-text-primary"
              phx-click="export_json"
            >
              <span class="hero-arrow-down-tray-mini h-4 w-4"></span> JSON
            </button>

            <a
              :if={@export_data_json}
              download={"tool-traces-#{Date.utc_today()}.json"}
              href={"data:application/json;charset=utf-8,#{URI.encode(@export_data_json)}"}
              title="Download JSON"
              aria-label="Download JSON"
              class="inline-flex items-center justify-center gap-1.5 rounded-lg border border-success/20 bg-success/10 px-3 py-2 min-h-[40px] text-sm font-510 text-success transition-colors hover:bg-success/15"
            >
              <span class="hero-arrow-down-tray-mini h-4 w-4"></span> JSON
            </a>

            <button
              :if={!@export_data_csv}
              type="button"
              title="Export CSV"
              aria-label="Export CSV"
              class="inline-flex items-center justify-center gap-1.5 rounded-lg border border-border bg-button px-3 py-2 min-h-[40px] text-sm font-510 text-text-secondary transition-colors hover:bg-button-hover hover:text-text-primary"
              phx-click="export_csv"
            >
              <span class="hero-arrow-down-tray-mini h-4 w-4"></span> CSV
            </button>

            <a
              :if={@export_data_csv}
              download={"tool-traces-#{Date.utc_today()}.csv"}
              href={"data:text/csv;charset=utf-8,#{URI.encode(@export_data_csv)}"}
              title="Download CSV"
              aria-label="Download CSV"
              class="inline-flex items-center justify-center gap-1.5 rounded-lg border border-success/20 bg-success/10 px-3 py-2 min-h-[40px] text-sm font-510 text-success transition-colors hover:bg-success/15"
            >
              <span class="hero-arrow-down-tray-mini h-4 w-4"></span> CSV
            </a>
          </div>

          <div class={"text-sm font-510 " <> integrity_status_color(@integrity_status)}>
            {integrity_status_label(@integrity_status)}
          </div>
        </div>

        <form
          id="trace-filters"
          phx-change="filter"
          phx-submit="filter"
          class="mb-6 scroll-mt-6 bg-surface border border-border rounded-xl p-4"
        >
          <div class="grid grid-cols-1 md:grid-cols-5 gap-4 mb-4">
            <div>
              <label class="block text-xs font-510 text-text-secondary mb-1.5">Tool Name</label>
              <input
                type="text"
                name="filter[tool_name]"
                value={@filters.tool_name}
                placeholder="Filter by tool name..."
                class="w-full rounded-lg border border-border bg-panel px-3 py-2 text-sm text-text-primary placeholder:text-text-quaternary focus:border-brand focus:outline-none focus:ring-2 focus:ring-brand/30"
              />
            </div>

            <div>
              <label class="block text-xs font-510 text-text-secondary mb-1.5">Status</label>
              <.select_menu
                label="Status"
                name="filter[status]"
                value={@filters.status || ""}
                options={[
                  {"All Statuses", ""},
                  {"Success", "success"},
                  {"Error", "error"},
                  {"Pending", "pending"},
                  {"Timeout", "timeout"}
                ]}
              />
            </div>

            <div>
              <label class="block text-xs font-510 text-text-secondary mb-1.5">Agent</label>
              <.select_menu
                label="Agent"
                name="filter[agent_id]"
                value={@filters.agent_id || ""}
                options={[{"All Agents", ""} | Enum.map(@agents, &{&1.name, &1.id})]}
              />
            </div>

            <div>
              <label class="block text-xs font-510 text-text-secondary mb-1.5">Issue ID</label>
              <input
                type="text"
                name="filter[issue_id]"
                value={@filters.issue_id}
                placeholder="Filter by issue ID..."
                class="w-full rounded-lg border border-border bg-panel px-3 py-2 text-sm text-text-primary placeholder:text-text-quaternary focus:border-brand focus:outline-none focus:ring-2 focus:ring-brand/30"
              />
            </div>

            <div>
              <label class="block text-xs font-510 text-text-secondary mb-1.5">Run ID</label>
              <input
                type="text"
                name="filter[run_id]"
                value={Map.get(@filters, :run_id, "")}
                placeholder="Filter by run ID..."
                class="w-full rounded-lg border border-border bg-panel px-3 py-2 text-sm text-text-primary placeholder:text-text-quaternary focus:border-brand focus:outline-none focus:ring-2 focus:ring-brand/30"
              />
            </div>
          </div>

          <%!-- Filters apply on change like every other filter bar, so there is
               no Apply button and Clear is an icon. --%>
          <div class="flex gap-2">
            <button
              type="button"
              title="Clear Filters"
              aria-label="Clear Filters"
              class="inline-flex h-10 w-10 items-center justify-center rounded-lg border border-border bg-button text-text-secondary transition-colors hover:bg-button-hover hover:text-text-primary"
              phx-click="clear_filters"
            >
              <span class="hero-x-mark-mini h-4 w-4"></span>
            </button>
          </div>
        </form>

        <%!-- Total/Success/Errors/Pending already sit in the Trace command
             strip; the big-card copy of the same four numbers is gone. --%>

        <div class="grid grid-cols-1 lg:grid-cols-3 gap-6 min-w-0">
          <div class="lg:col-span-2 min-w-0">
            <div
              id="traces-table"
              class="scroll-mt-6 bg-surface border border-border rounded-xl overflow-hidden"
            >
              <div class="px-4 py-3 border-b border-border">
                <h2 class="text-sm font-590 text-text-primary">Traces</h2>
              </div>

              <div class="overflow-x-auto">
                <table class="w-full">
                  <thead class="bg-subtle">
                    <tr>
                      <th class="px-4 py-3 text-left text-xs font-medium text-text-secondary uppercase tracking-wider">
                        Seq
                      </th>
                      <th class="px-4 py-3 text-left text-xs font-medium text-text-secondary uppercase tracking-wider">
                        Tool
                      </th>
                      <th class="px-4 py-3 text-left text-xs font-medium text-text-secondary uppercase tracking-wider">
                        Actor
                      </th>
                      <th class="px-4 py-3 text-left text-xs font-medium text-text-secondary uppercase tracking-wider">
                        Status
                      </th>
                      <th class="hidden px-4 py-3 text-left text-xs font-medium text-text-secondary uppercase tracking-wider md:table-cell">
                        Time
                      </th>
                      <th class="hidden px-4 py-3 text-left text-xs font-medium text-text-secondary uppercase tracking-wider md:table-cell">
                        Chain Hash
                      </th>
                    </tr>
                  </thead>
                  <tbody id="traces-tbody" phx-update="stream" class="divide-y divide-border">
                    <tr id="traces-empty" class="only:table-row hidden">
                      <td colspan="6" class="p-8 text-center">
                        <div class="mx-auto max-w-md">
                          <p class="text-sm font-590 text-text-primary">
                            {if filters_active?(@filters),
                              do: "No traces match these filters",
                              else: "No tool evidence captured yet"}
                          </p>
                          <p class="mt-1 text-sm leading-5 text-text-tertiary">
                            {if filters_active?(@filters),
                              do:
                                "Clear filters to return to the full trace chain, or open Operations if you expected runtime activity.",
                              else: "Launch runtime from Operations and every tool call lands here."}
                          </p>
                          <div class="mt-4 flex flex-wrap items-center justify-center gap-2">
                            <button
                              :if={filters_active?(@filters)}
                              type="button"
                              phx-click="clear_filters"
                              class="inline-flex items-center gap-1.5 rounded-lg border border-border bg-surface px-3 py-2 text-xs font-510 text-text-secondary transition-colors hover:bg-surface-hover hover:text-text-primary"
                            >
                              Clear filters
                            </button>
                            <a
                              href="/operations#runtime-launch-checklist"
                              class="inline-flex items-center gap-1.5 rounded-lg border border-brand/25 bg-brand/10 px-3 py-2 text-xs font-510 text-brand transition-colors hover:bg-brand/15"
                            >
                              Open Operations
                            </a>
                          </div>
                        </div>
                      </td>
                    </tr>
                    <tr
                      :for={{dom_id, trace} <- @streams.traces}
                      id={dom_id}
                      class={
                        if @selected_trace && @selected_trace.id == trace.id,
                          do: "bg-brand/10 cursor-pointer",
                          else: "hover:bg-subtle cursor-pointer"
                      }
                      phx-click="select_trace"
                      phx-value-id={trace.id}
                    >
                      <td class="px-4 py-3 whitespace-nowrap text-sm text-text-primary">
                        {trace.sequence_number}
                      </td>
                      <td class="px-4 py-3 text-sm text-text-primary">
                        <div class="font-medium">{trace.tool_name}</div>
                        <div class="text-xs text-text-secondary">{trace.trace_type}</div>
                      </td>
                      <td class="px-4 py-3 text-sm text-text-secondary">
                        <div class="flex items-center gap-1">
                          <span class="text-xs capitalize">{trace.actor_type}</span>
                          <%= if trace.actor_type == "agent" && trace.agent do %>
                            <span class="text-xs text-text-tertiary">({trace.agent.name})</span>
                          <% end %>
                        </div>
                      </td>
                      <td class={"px-4 py-3 whitespace-nowrap text-sm " <> status_color(trace.status)}>
                        <span class="inline-flex items-center">
                          <span class="mr-1">{status_icon(trace.status)}</span>
                          {String.capitalize(trace.status)}
                        </span>
                      </td>
                      <td class="hidden px-4 py-3 whitespace-nowrap text-sm text-text-secondary md:table-cell">
                        {format_datetime(trace.occurred_at)}
                      </td>
                      <td class="hidden px-4 py-3 text-xs text-text-secondary font-mono md:table-cell">
                        {String.slice(trace.chain_hash, 0..7)}...
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </div>
            <.infinite_scroll_footer
              id="traces"
              has_more={@infinite_scroll[:traces][:has_more?] || false}
            />
          </div>

          <%= if @selected_trace do %>
            <div class="lg:col-span-1">
              <div class="bg-surface border border-border rounded-xl sticky top-4">
                <div class="px-4 py-3 border-b border-border flex items-center justify-between">
                  <h2 class="text-sm font-590 text-text-primary">Trace Details</h2>
                  <button
                    type="button"
                    class="p-1 hover:bg-surface-hover rounded"
                    phx-click="close_trace_details"
                    aria-label="Close trace details"
                    title="Close trace details"
                  >
                    <svg
                      class="w-5 h-5 text-text-secondary"
                      fill="none"
                      stroke="currentColor"
                      viewBox="0 0 24 24"
                    >
                      <path
                        stroke-linecap="round"
                        stroke-linejoin="round"
                        stroke-width="2"
                        d="M6 18L18 6M6 6l12 12"
                      />
                    </svg>
                  </button>
                </div>

                <div class="p-4 space-y-4">
                  <% recovery = trace_recovery(@selected_trace) %>
                  <div
                    :if={recovery}
                    id={"trace-recovery-#{@selected_trace.id}"}
                    class="rounded-lg border border-amber-500/25 bg-amber-500/[0.06] px-3 py-3"
                  >
                    <div class="flex flex-wrap items-center justify-between gap-2">
                      <p class="text-xs font-590 uppercase tracking-[0.12em] text-amber-200">
                        {recovery.title}
                      </p>
                      <span class="rounded-full border border-amber-500/25 bg-amber-500/10 px-2 py-0.5 text-[11px] font-510 text-amber-200">
                        {String.capitalize(@selected_trace.status)}
                      </span>
                    </div>
                    <p class="mt-2 text-xs leading-5 text-text-tertiary">
                      {recovery.summary}
                    </p>
                    <div class="mt-3 flex flex-wrap gap-2">
                      <a
                        :if={recovery.issue_path}
                        href={recovery.issue_path}
                        class="inline-flex items-center rounded-md border border-border bg-panel px-2.5 py-1.5 text-xs font-510 text-text-secondary hover:border-brand/40 hover:bg-surface-hover hover:text-text-primary"
                      >
                        Open issue
                      </a>
                      <a
                        href={recovery.operations_path}
                        class="inline-flex items-center rounded-md border border-border bg-panel px-2.5 py-1.5 text-xs font-510 text-text-secondary hover:border-brand/40 hover:bg-surface-hover hover:text-text-primary"
                      >
                        Open runtime failures
                      </a>
                    </div>
                    <div
                      :if={recovery.focused_command}
                      id={"trace-focused-command-#{@selected_trace.id}"}
                      phx-hook="CopyToClipboard"
                      class="mt-3 rounded-md border border-border bg-canvas px-3 py-2"
                    >
                      <div class="mb-2 flex flex-wrap items-center justify-between gap-2">
                        <span class="text-[10px] font-590 uppercase tracking-[0.14em] text-text-quaternary">
                          Focused relaunch
                        </span>
                        <button
                          type="button"
                          data-copy-text={recovery.focused_command}
                          data-copy-label="Copy command"
                          class="rounded-md border border-border bg-panel px-2 py-1 text-[11px] font-510 text-text-secondary hover:bg-surface-hover hover:text-text-primary"
                        >
                          Copy command
                        </button>
                      </div>
                      <code class="block whitespace-pre-wrap break-words font-mono text-[11px] leading-5 text-text-secondary">
                        {recovery.focused_command}
                      </code>
                    </div>
                  </div>

                  <div>
                    <div class="text-xs text-text-secondary mb-1">Sequence Number</div>
                    <div class="text-sm font-mono text-text-primary">
                      {@selected_trace.sequence_number}
                    </div>
                  </div>

                  <div>
                    <div class="text-xs text-text-secondary mb-1">Tool Name</div>
                    <div class="text-sm font-medium text-text-primary">
                      {@selected_trace.tool_name}
                    </div>
                  </div>

                  <div>
                    <div class="text-xs text-text-secondary mb-1">Trace Type</div>
                    <div class="text-sm text-text-primary">{@selected_trace.trace_type}</div>
                  </div>

                  <div>
                    <div class="text-xs text-text-secondary mb-1">Status</div>
                    <div class={"text-sm font-medium " <> status_color(@selected_trace.status)}>
                      <span class="inline-flex items-center">
                        <span class="mr-1">{status_icon(@selected_trace.status)}</span>
                        {String.capitalize(@selected_trace.status)}
                      </span>
                    </div>
                  </div>

                  <div>
                    <div class="text-xs text-text-secondary mb-1">Occurred At</div>
                    <div class="text-sm text-text-primary">
                      {format_datetime(@selected_trace.occurred_at)}
                    </div>
                  </div>

                  <div>
                    <div class="text-xs text-text-secondary mb-1">Content Hash</div>
                    <div class="text-xs font-mono text-text-secondary break-all">
                      {@selected_trace.content_hash}
                    </div>
                  </div>

                  <div>
                    <div class="text-xs text-text-secondary mb-1">Previous Hash</div>
                    <div class="text-xs font-mono text-text-secondary break-all">
                      {@selected_trace.prev_hash || "None (genesis trace)"}
                    </div>
                  </div>

                  <div>
                    <div class="text-xs text-text-secondary mb-1">Chain Hash</div>
                    <div class="text-xs font-mono text-text-secondary break-all">
                      {@selected_trace.chain_hash}
                    </div>
                  </div>

                  <div>
                    <div class="text-xs text-text-secondary mb-1">Actor Type</div>
                    <div class="text-sm text-text-primary capitalize">
                      {@selected_trace.actor_type}
                    </div>
                  </div>

                  <div>
                    <div class="text-xs text-text-secondary mb-1">Actor ID</div>
                    <div class="text-sm font-mono text-text-primary">{@selected_trace.actor_id}</div>
                  </div>

                  <%= if @selected_trace.actor_type == "agent" && @selected_trace.agent do %>
                    <div>
                      <div class="text-xs text-text-secondary mb-1">Agent Name</div>
                      <div class="text-sm text-text-primary">{@selected_trace.agent.name}</div>
                    </div>
                  <% end %>

                  <%= if @selected_trace.agent_id do %>
                    <div>
                      <div class="text-xs text-text-secondary mb-1">Original Agent ID</div>
                      <div class="text-sm font-mono text-text-primary">
                        {@selected_trace.agent_id}
                      </div>
                    </div>
                  <% end %>

                  <%= if @selected_trace.issue_id do %>
                    <div>
                      <div class="text-xs text-text-secondary mb-1">Issue ID</div>
                      <div class="text-sm font-mono text-text-primary">
                        {@selected_trace.issue_id}
                      </div>
                    </div>
                  <% end %>

                  <%= if @selected_trace.run_id do %>
                    <div>
                      <div class="text-xs text-text-secondary mb-1">Run ID</div>
                      <div class="text-sm font-mono text-text-primary">
                        {@selected_trace.run_id}
                      </div>
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
    </div>
    """
  end
end
