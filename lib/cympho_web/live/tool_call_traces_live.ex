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
      |> assign(:page_title, "Step log")
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

  # Trace states as a word plus a shape (v7 §1.5).
  defp trace_status("success"), do: {:done, "OK"}
  defp trace_status("error"), do: {:stopped, "Failed"}
  defp trace_status("timeout"), do: {:stopped, "Timed out"}
  defp trace_status("pending"), do: {:idle, "Pending"}
  defp trace_status(status), do: {:idle, String.capitalize(to_string(status))}

  defp integrity_kind(:ok), do: :done
  defp integrity_kind(:unknown), do: :idle
  defp integrity_kind(_status), do: :stopped

  defp active_filter_count(filters),
    do: Enum.count(filters, fn {_key, value} -> value not in [nil, ""] end)

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
      title: "Stop trusting trace exports until integrity is repaired",
      summary: integrity_failure_summary(integrity_status),
      # The chain check is the page's header control; the band repeats no button.
      action_label: nil,
      action_path: nil,
      metrics: trace_command_metrics(statistics)
    }
  end

  defp build_trace_command(%{statistics: %{error_calls: errors} = statistics}) when errors > 0 do
    %{
      title: "Inspect failed tool calls",
      summary:
        "#{pluralize(errors, "tool call")} ended in error. Filter the trace list, open the failing row, and compare arguments to the tool result.",
      action_label: "Filter failures",
      action_path: "#trace-filters",
      metrics: trace_command_metrics(statistics)
    }
  end

  defp build_trace_command(%{statistics: %{pending_calls: pending} = statistics})
       when pending > 0 do
    %{
      title: "Check unfinished tool calls",
      summary:
        "#{pluralize(pending, "tool call")} are still pending or timed out. Filter pending traces before relaunching the same issue.",
      action_label: "Review pending",
      action_path: "#trace-filters",
      metrics: trace_command_metrics(statistics)
    }
  end

  defp build_trace_command(%{statistics: %{total_calls: 0} = statistics}) do
    %{
      title: "Launch runtime to capture tool evidence",
      summary: "Nothing recorded yet. Tool calls appear here as soon as agents start working.",
      action_label: "Open Health",
      action_path: "/operations#runtime-launch-checklist",
      metrics: trace_command_metrics(statistics)
    }
  end

  defp build_trace_command(%{integrity_status: :unknown, statistics: statistics}) do
    %{
      title: "Verify the audit chain",
      summary:
        "Trace capture is available, but the chain has not been checked in this session. Verify before exporting evidence.",
      action_label: nil,
      action_path: nil,
      metrics: trace_command_metrics(statistics)
    }
  end

  defp build_trace_command(%{statistics: statistics}) do
    %{
      title: "Tool evidence is audit-ready",
      summary:
        "All current tool calls are successful and the trace chain is ready for export or issue-level review.",
      action_label: "Review traces",
      action_path: "#traces-table",
      metrics: trace_command_metrics(statistics)
    }
  end

  defp integrity_failure_summary({:error, :content_hash_mismatch, sequence}) do
    "Trace sequence #{sequence} has content modified since last review. Inspect that row before using exports for audit or governance."
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

  def format_json(map) when is_map(map) do
    map
    |> Jason.encode!(pretty: true)
  end

  def format_json(_), do: ""

  @impl true
  def render(assigns) do
    ~H"""
    <.page_frame page="steps" title="Step log" data-ui-complex-page>
      <:header_end>
        <.pill phx-click="verify_integrity">
          <.r3_icon name="i-shield" />Check the chain
        </.pill>
      </:header_end>

      <.flash_line flash={@flash} />

      <.band_card
        id="trace-command-t"
        title="Audit chain"
        section_id="trace-command"
        data-testid="trace-command"
      >
        <:header_end>
          <span class="st-w">
            <.status_word
              kind={integrity_kind(@integrity_status)}
              word={integrity_status_label(@integrity_status)}
            />
          </span>
        </:header_end>
        <div class="gl-sec">
          <p class="gl-big">{@trace_command.title}</p>
          <p class="gl-sub">{@trace_command.summary}</p>
          <.text_link :if={@trace_command.action_path} href={@trace_command.action_path}>
            {@trace_command.action_label}
          </.text_link>
        </div>
        <div class="strip st-strip">
          <div :for={metric <- @trace_command.metrics} class="cell">
            <span class="v mono">{metric.value}</span><span class="l">{metric.label}</span>
          </div>
        </div>
      </.band_card>

      <div class="tbar">
        <.filter_menu id="trace-filter" active={active_filter_count(@filters)}>
          <form id="trace-filters" class="st-f" phx-change="filter" phx-submit="filter">
            <div class="flds">
              <.input
                id="trace-filter-tool"
                name="filter[tool_name]"
                value={@filters.tool_name}
                label="Tool"
                placeholder="read_file"
                autocomplete="off"
              />
              <.input
                type="select"
                id="trace-filter-status"
                name="filter[status]"
                value={@filters.status || ""}
                label="Status"
                options={[
                  {"All statuses", ""},
                  {"OK", "success"},
                  {"Failed", "error"},
                  {"Pending", "pending"},
                  {"Timed out", "timeout"}
                ]}
              />
              <.input
                type="select"
                id="trace-filter-agent"
                name="filter[agent_id]"
                value={@filters.agent_id || ""}
                label="Agent"
                options={[{"All agents", ""} | Enum.map(@agents, &{&1.name, &1.id})]}
              />
              <.input
                id="trace-filter-issue"
                name="filter[issue_id]"
                value={@filters.issue_id}
                label="Task ID"
                autocomplete="off"
              />
              <.input
                id="trace-filter-run"
                name="filter[run_id]"
                value={Map.get(@filters, :run_id, "")}
                label="Run ID"
                wrapper_class="full"
                autocomplete="off"
              />
            </div>
          </form>
          <button :if={filters_active?(@filters)} type="button" class="lnk" phx-click="clear_filters">
            Clear filters
          </button>
        </.filter_menu>
      </div>

      <div class={["st-split", @selected_trace && "st-open"]}>
        <.band_card id="traces-t" title="Steps" section_id="traces-table">
          <:header_end>
            <span class="st-x">
              <.pill :if={!@export_data_json} phx-click="export_json">Export JSON</.pill>
              <a
                :if={@export_data_json}
                class="pl"
                download={"tool-traces-#{Date.utc_today()}.json"}
                href={"data:application/json;charset=utf-8,#{URI.encode(@export_data_json)}"}
              >
                Download JSON
              </a>
              <.pill :if={!@export_data_csv} phx-click="export_csv">Export CSV</.pill>
              <a
                :if={@export_data_csv}
                class="pl"
                download={"tool-traces-#{Date.utc_today()}.csv"}
                href={"data:text/csv;charset=utf-8,#{URI.encode(@export_data_csv)}"}
              >
                Download CSV
              </a>
            </span>
          </:header_end>

          <div class="tbl-w">
            <table class="tbl" id="traces-tbl">
              <thead>
                <tr>
                  <th scope="col">Seq</th>
                  <th scope="col">Tool</th>
                  <th scope="col" class="m-hide">Actor</th>
                  <th scope="col">Status</th>
                  <th scope="col" class="m-hide">Time</th>
                  <th scope="col" class="m-hide">Chain hash</th>
                </tr>
              </thead>
              <tbody id="traces-tbody" phx-update="stream">
                <tr id="traces-empty" class="only:table-row hidden">
                  <td colspan="6">
                    <.quiet_empty title={
                      if filters_active?(@filters),
                        do: "No traces match these filters",
                        else: "No tool evidence captured yet"
                    }>
                      {if filters_active?(@filters),
                        do:
                          "Clear filters to return to the full trace chain, or open Health if you expected runtime activity.",
                        else: "Launch runtime from Health and every tool call lands here."}
                      <:action>
                        <span class="st-x">
                          <.pill :if={filters_active?(@filters)} phx-click="clear_filters">
                            Clear filters
                          </.pill>
                          <.text_link href="/operations#runtime-launch-checklist">
                            Open Health
                          </.text_link>
                        </span>
                      </:action>
                    </.quiet_empty>
                  </td>
                </tr>
                <tr
                  :for={{dom_id, trace} <- @streams.traces}
                  id={dom_id}
                  class="st-row"
                  aria-current={@selected_trace && @selected_trace.id == trace.id && "true"}
                  phx-click="select_trace"
                  phx-value-id={trace.id}
                >
                  <td>
                    <button
                      type="button"
                      class="ul mono"
                      phx-click="select_trace"
                      phx-value-id={trace.id}
                      aria-label={"Open step #{trace.sequence_number}"}
                    >
                      {trace.sequence_number}
                    </button>
                  </td>
                  <td>
                    <span class="st-tool">{trace.tool_name}</span>
                    <span class="st-sub">{trace.trace_type}</span>
                  </td>
                  <td class="m-hide">
                    {String.capitalize(to_string(trace.actor_type))}<span
                      :if={trace.actor_type == "agent" && trace.agent}
                      class="st-sub"
                    >{trace.agent.name}</span>
                  </td>
                  <td>
                    <span class="st-w">
                      <.status_word
                        kind={elem(trace_status(trace.status), 0)}
                        word={elem(trace_status(trace.status), 1)}
                      />
                    </span>
                  </td>
                  <td class="m-hide">
                    <span class="mono">{CymphoWeb.AgentLive.Parts.stamp(trace.occurred_at)}</span>
                  </td>
                  <td class="m-hide">
                    <span class="mono">{String.slice(trace.chain_hash, 0..7)}…</span>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
          <.infinite_scroll_footer
            id="traces"
            has_more={@infinite_scroll[:traces][:has_more?] || false}
          />
        </.band_card>

        <.band_card :if={@selected_trace} id="trace-det-t" title="Step details" class="st-det">
          <:header_end>
            <.pill phx-click="close_trace_details" aria-label="Close step details">Close</.pill>
          </:header_end>

          <% recovery = trace_recovery(@selected_trace) %>
          <div :if={recovery} id={"trace-recovery-#{@selected_trace.id}"} class="st-rec">
            <p class="st-rec-h">
              <.status_word
                kind={elem(trace_status(@selected_trace.status), 0)}
                word={recovery.title}
              />
            </p>
            <p class="gl-sub">{recovery.summary}</p>
            <p class="st-x">
              <.text_link :if={recovery.issue_path} href={recovery.issue_path}>
                Open task
              </.text_link>
              <.text_link href={recovery.operations_path}>Open runtime failures</.text_link>
            </p>
            <div
              :if={recovery.focused_command}
              id={"trace-focused-command-#{@selected_trace.id}"}
              class="st-cmd"
              phx-hook="CopyToClipboard"
            >
              <div class="st-cmd-h">
                <span class="gh">Focused relaunch</span>
                <button
                  type="button"
                  class="pl"
                  data-copy-text={recovery.focused_command}
                  data-copy-label="Copy command"
                >
                  Copy command
                </button>
              </div>
              <code class="st-well mono">{recovery.focused_command}</code>
            </div>
          </div>

          <.kv_list>
            <:item term="Sequence">
              <span class="mono">{@selected_trace.sequence_number}</span>
            </:item>
            <:item term="Tool">{@selected_trace.tool_name}</:item>
            <:item term="Type">{@selected_trace.trace_type}</:item>
            <:item term="Status">
              <span class="st-w">
                <.status_word
                  kind={elem(trace_status(@selected_trace.status), 0)}
                  word={elem(trace_status(@selected_trace.status), 1)}
                />
              </span>
            </:item>
            <:item term="When">
              {Calendar.strftime(@selected_trace.occurred_at, "%a %-d %b")}
              <span class="mono">{Calendar.strftime(@selected_trace.occurred_at, "%H:%M:%S")}</span>
            </:item>
            <:item term="Actor">
              {String.capitalize(to_string(@selected_trace.actor_type))}<span :if={
                @selected_trace.actor_type == "agent" && @selected_trace.agent
              }> · {@selected_trace.agent.name}</span>
            </:item>
            <:item term="Actor ID">
              <span class="mono st-hash">{@selected_trace.actor_id}</span>
            </:item>
            <:item :if={@selected_trace.agent_id} term="Agent ID">
              <span class="mono st-hash">{@selected_trace.agent_id}</span>
            </:item>
            <:item :if={@selected_trace.issue_id} term="Task ID">
              <span class="mono st-hash">{@selected_trace.issue_id}</span>
            </:item>
            <:item :if={@selected_trace.run_id} term="Run ID">
              <span class="mono st-hash">{@selected_trace.run_id}</span>
            </:item>
            <:item term="Content hash">
              <span class="mono st-hash">{@selected_trace.content_hash}</span>
            </:item>
            <:item term="Previous hash">
              <span class="mono st-hash">
                {@selected_trace.prev_hash || "None (genesis trace)"}
              </span>
            </:item>
            <:item term="Chain hash">
              <span class="mono st-hash">{@selected_trace.chain_hash}</span>
            </:item>
          </.kv_list>

          <div :if={@selected_trace.tool_arguments != %{}} class="st-blk">
            <p class="gh">Arguments</p>
            <pre class="st-well mono"><%= format_json(@selected_trace.tool_arguments) %></pre>
          </div>
          <div :if={@selected_trace.tool_result} class="st-blk">
            <p class="gh">Result</p>
            <pre class="st-well mono st-tall"><%= @selected_trace.tool_result %></pre>
          </div>
          <div :if={@selected_trace.error_message} class="st-blk">
            <p class="gh">Error</p>
            <pre class="st-well mono st-err"><%= @selected_trace.error_message %></pre>
          </div>
        </.band_card>
      </div>
    </.page_frame>
    """
  end
end
