defmodule CymphoWeb.IssueLive.Show.SwarmPanel do
  @moduledoc """
  Renders the swarm-specific delivery path on issue detail pages.
  """
  use CymphoWeb, :html

  alias Cympho.Agents.Agent

  attr :issue, :map, required: true
  attr :child_tree, :list, default: []
  attr :swarm_events, :list, default: []

  def swarm_panel(assigns) do
    assigns =
      assign(
        assigns,
        :panel,
        panel_data(assigns.issue, assigns.child_tree, assigns.swarm_events)
      )

    ~H"""
    <section
      :if={@panel}
      id="issue-swarm-panel"
      data-testid="issue-swarm-panel"
      class="px-4 pb-5 lg:px-6"
    >
      <div class="border-y border-hairline bg-surface-1/25 px-1 py-4">
        <div class="flex flex-col gap-4 xl:flex-row xl:items-start xl:justify-between">
          <div class="min-w-0 flex-1">
            <div class="flex flex-wrap items-center gap-2">
              <span class="inline-flex h-7 w-7 items-center justify-center rounded-md border border-brand/20 bg-brand/10 text-brand">
                <.icon name="hero-bolt-mini" class="h-4 w-4" />
              </span>
              <p class="text-eyebrow uppercase text-ink-tertiary">{@panel.eyebrow}</p>
              <span class={phase_badge_class(@panel.phase_state)}>{@panel.phase_label}</span>
            </div>
            <p class="mt-2 max-w-3xl text-sm leading-6 text-ink-secondary">
              {@panel.summary}
            </p>
            <div :if={@panel.protocol != []} class="mt-3 flex flex-wrap gap-1.5">
              <span
                :for={rule <- @panel.protocol}
                class="rounded-full border border-hairline bg-canvas px-2 py-0.5 text-[10px] font-510 uppercase tracking-[0.04em] text-ink-tertiary"
              >
                {rule}
              </span>
            </div>
          </div>

          <div class="grid min-w-0 grid-cols-2 gap-px overflow-hidden rounded-md border border-hairline bg-hairline sm:grid-cols-4 xl:w-80 xl:grid-cols-2">
            <div :for={metric <- @panel.metrics} class="bg-canvas px-3 py-2.5">
              <p class="text-[10px] font-590 uppercase tracking-[0.1em] text-ink-tertiary">
                {metric.label}
              </p>
              <p class="mt-1 break-words text-sm font-510 leading-5 text-ink">{metric.value}</p>
            </div>
          </div>
        </div>

        <div class="mt-4 grid gap-2 md:grid-cols-3">
          <div :for={step <- @panel.steps} class={step_class(step.state)}>
            <div class="flex items-center justify-between gap-2">
              <p class="text-xs font-590 text-ink">{step.title}</p>
              <span class={step_dot_class(step.state)}></span>
            </div>
            <p class="mt-1 text-[11px] leading-4 text-ink-tertiary">{step.detail}</p>
          </div>
        </div>

        <div
          data-testid="issue-swarm-log"
          class="mt-4 overflow-hidden rounded-md border border-hairline bg-canvas"
        >
          <div class="flex items-center justify-between gap-3 border-b border-hairline px-3 py-2.5">
            <div class="flex min-w-0 items-center gap-2">
              <span class="inline-flex h-6 w-6 items-center justify-center rounded-md border border-teal-500/20 bg-teal-500/10 text-teal-300">
                <.icon name="hero-signal-mini" class="h-3.5 w-3.5" />
              </span>
              <div class="min-w-0">
                <h2 class="text-xs font-590 text-ink">Live swarm log</h2>
                <p class="text-[11px] text-ink-tertiary">
                  Launch, worker, CTO, and CEO handoff events.
                </p>
              </div>
            </div>
            <span class="shrink-0 rounded-full border border-hairline bg-surface-1 px-2 py-0.5 text-[10px] font-590 uppercase text-ink-tertiary">
              {length(@panel.events)} events
            </span>
          </div>

          <div :if={@panel.events == []} class="px-3 py-3 text-xs text-ink-tertiary">
            Waiting for the first swarm event.
          </div>

          <ol :if={@panel.events != []} class="max-h-64 divide-y divide-hairline overflow-y-auto">
            <li
              :for={event <- @panel.events}
              class="grid gap-2 px-3 py-2.5 sm:grid-cols-[6.5rem_minmax(0,1fr)]"
            >
              <div class="flex items-center gap-2 text-[11px] text-ink-tertiary">
                <span class={event_dot_class(event.status)}></span>
                <span class="font-mono">{event.time}</span>
              </div>
              <div class="min-w-0">
                <div class="flex flex-wrap items-center gap-2">
                  <span class={event_badge_class(event.status)}>{event.type_label}</span>
                  <p class="min-w-0 flex-1 text-xs leading-5 text-ink">
                    {event.message}
                  </p>
                </div>
                <div :if={event.chips != []} class="mt-1 flex flex-wrap gap-1.5">
                  <span
                    :for={chip <- event.chips}
                    class="max-w-full truncate rounded-full border border-hairline bg-surface-1 px-2 py-0.5 text-[10px] text-ink-tertiary"
                  >
                    {chip}
                  </span>
                </div>
              </div>
            </li>
          </ol>
        </div>

        <div
          :if={show_detail_grid?(@panel)}
          class="mt-4 grid gap-4 border-t border-hairline pt-4 xl:grid-cols-[minmax(0,1fr)_22rem]"
        >
          <div :if={@panel.workers != []} class="min-w-0">
            <div class="flex items-center justify-between gap-3">
              <h2 class="text-eyebrow uppercase text-ink-tertiary">Worker packets</h2>
              <span class="text-caption text-ink-tertiary">
                {@panel.worker_done}/{@panel.worker_total} closed
              </span>
            </div>
            <div class="mt-2 grid gap-2 md:grid-cols-2">
              <.app_link
                :for={worker <- @panel.workers}
                navigate={~p"/issues/#{worker.id}"}
                class="group rounded-md border border-hairline bg-canvas px-3 py-2.5 transition hover:border-border-hover hover:bg-surface-1"
              >
                <div class="flex items-start justify-between gap-3">
                  <div class="min-w-0">
                    <div class="flex flex-wrap items-center gap-2">
                      <span class="rounded-full border border-brand/20 bg-brand/10 px-2 py-0.5 text-[10px] font-590 uppercase tracking-[0.04em] text-brand">
                        {worker.label}
                      </span>
                      <span class="text-sm font-590 text-ink group-hover:text-primary">
                        {worker.role}
                      </span>
                      <span class="font-mono text-[11px] text-ink-tertiary">
                        {worker.identifier}
                      </span>
                    </div>
                    <p class="mt-1 line-clamp-1 text-xs text-ink-tertiary">{worker.title}</p>
                  </div>
                  <span class={status_pill_class(worker.status)}>{worker.status_label}</span>
                </div>
                <div class="mt-2 flex flex-wrap gap-1.5">
                  <span class="rounded-full border border-hairline bg-surface-1 px-2 py-0.5 font-mono text-[10px] text-ink-tertiary">
                    {worker.harness}
                  </span>
                  <span class="rounded-full border border-hairline bg-surface-1 px-2 py-0.5 font-mono text-[10px] text-ink-tertiary">
                    {worker.model}
                  </span>
                  <span class="rounded-full border border-hairline bg-surface-1 px-2 py-0.5 text-[10px] text-ink-tertiary">
                    {worker.reasoning}
                  </span>
                  <span
                    :if={worker.proxy_profile}
                    class="rounded-full border border-emerald-500/20 bg-emerald-500/10 px-2 py-0.5 text-[10px] text-emerald-300"
                  >
                    {worker.proxy_profile}
                  </span>
                  <span
                    :if={worker.lens}
                    class="rounded-full border border-brand/20 bg-brand/10 px-2 py-0.5 text-[10px] text-brand"
                  >
                    {worker.lens}
                  </span>
                </div>
              </.app_link>
            </div>
          </div>

          <div class="space-y-2">
            <.app_link
              :if={@panel.cto}
              navigate={~p"/issues/#{@panel.cto.id}"}
              class="block rounded-md border border-hairline bg-canvas px-3 py-3 transition hover:border-border-hover hover:bg-surface-1"
            >
              <div class="flex items-start justify-between gap-3">
                <div class="min-w-0">
                  <p class="text-[10px] font-590 uppercase tracking-[0.1em] text-ink-tertiary">
                    CTO gate
                  </p>
                  <p class="mt-1 truncate text-sm font-590 text-ink group-hover:text-primary">
                    {@panel.cto.title}
                  </p>
                  <p class="mt-1 font-mono text-[11px] text-ink-tertiary">
                    {@panel.cto.identifier}
                  </p>
                </div>
                <span class={status_pill_class(@panel.cto.status)}>
                  {@panel.cto.status_label}
                </span>
              </div>
              <p class="mt-2 text-xs leading-5 text-ink-tertiary">
                {@panel.cto.detail}
              </p>
            </.app_link>

            <div
              :if={@panel.handoff}
              class="rounded-md border border-hairline bg-canvas px-3 py-3"
            >
              <div class="flex items-start justify-between gap-3">
                <div>
                  <p class="text-[10px] font-590 uppercase tracking-[0.1em] text-ink-tertiary">
                    CEO handoff
                  </p>
                  <p class="mt-1 text-sm font-590 text-ink">{@panel.handoff.title}</p>
                </div>
                <span class={status_pill_class(@panel.handoff.status)}>
                  {@panel.handoff.status_label}
                </span>
              </div>
              <p class="mt-2 text-xs leading-5 text-ink-tertiary">
                {@panel.handoff.detail}
              </p>
            </div>
          </div>
        </div>
      </div>
    </section>
    """
  end

  defp show_detail_grid?(%{workers: workers, cto: cto, handoff: handoff}) do
    workers != [] or not is_nil(cto) or not is_nil(handoff)
  end

  defp panel_data(issue, child_tree, swarm_events) do
    swarm = swarm_state(issue)

    panel =
      cond do
        swarm_parent?(issue, swarm) ->
          parent_panel(issue, swarm, child_tree)

        swarm_cto?(issue, swarm) ->
          cto_panel(issue, swarm)

        swarm_worker?(issue, swarm) ->
          worker_panel(issue, swarm)

        true ->
          nil
      end

    attach_events(panel, swarm_events)
  end

  defp attach_events(nil, _swarm_events), do: nil

  defp attach_events(panel, swarm_events) do
    Map.put(panel, :events, Enum.map(swarm_events, &event_row/1))
  end

  defp event_row(event) do
    %{
      id: event.id,
      type_label: event_type_label(event.event_type),
      status: event.status || "info",
      message: event.message,
      time: event_time(event.occurred_at || event.inserted_at),
      chips: event_chips(event.metadata || %{})
    }
  end

  defp event_type_label(type) when is_binary(type) do
    type
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp event_type_label(_type), do: "Event"

  defp event_time(%DateTime{} = time) do
    time
    |> DateTime.to_iso8601()
    |> String.slice(11, 8)
  end

  defp event_time(%NaiveDateTime{} = time) do
    time
    |> NaiveDateTime.to_iso8601()
    |> String.slice(11, 8)
  end

  defp event_time(_time), do: "--:--:--"

  defp event_chips(metadata) when is_map(metadata) do
    [
      count_chip(metadata, "agent_ids", "agents"),
      count_chip(metadata, "worker_issue_ids", "workers"),
      value_chip(metadata, "agent_count", "workers"),
      value_chip(metadata, "mix_rows", "mix rows"),
      prefixed_value_chip(metadata, "proxy_mode", "proxy"),
      prefixed_value_chip(metadata, "worker_index", "worker"),
      prefixed_value_chip(metadata, "role", "role"),
      short_value_chip(metadata, "summary"),
      short_value_chip(metadata, "reason")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.take(4)
  end

  defp event_chips(_metadata), do: []

  defp count_chip(metadata, key, label) do
    case metadata_value(metadata, key) do
      values when is_list(values) -> "#{length(values)} #{label}"
      _value -> nil
    end
  end

  defp value_chip(metadata, key, label) do
    case metadata_value(metadata, key) do
      value when is_integer(value) -> "#{value} #{label}"
      value when is_binary(value) and value != "" -> "#{value} #{label}"
      _value -> nil
    end
  end

  defp prefixed_value_chip(metadata, key, label) do
    case metadata_value(metadata, key) do
      value when is_integer(value) -> "#{label} #{value}"
      value when is_binary(value) and value != "" -> "#{label} #{value}"
      _value -> nil
    end
  end

  defp short_value_chip(metadata, key) do
    case metadata_value(metadata, key) do
      value when is_binary(value) and value != "" ->
        value
        |> String.replace(~r/\s+/, " ")
        |> String.slice(0, 90)

      _value ->
        nil
    end
  end

  defp metadata_value(metadata, key) do
    Map.get(metadata, key) || Map.get(metadata, swarm_atom_key(key))
  end

  defp parent_panel(issue, swarm, child_tree) do
    children = Enum.map(child_tree, & &1.issue)

    workers =
      children
      |> Enum.filter(&swarm_worker?/1)
      |> Enum.sort_by(&worker_index/1)

    cto = Enum.find(children, &swarm_cto?/1)
    worker_done = Enum.count(workers, &closed?/1)
    worker_total = max(length(workers), integer_value(swarm_value(swarm, "agent_count"), 0))
    phase = parent_phase(issue, worker_done, worker_total, cto)
    proxy = proxy_label(swarm)

    %{
      eyebrow: "Swarm orchestration",
      phase_label: phase.label,
      phase_state: phase.state,
      summary: parent_summary(phase.key),
      metrics: [
        %{label: "Workers", value: "#{worker_done}/#{worker_total} closed"},
        %{label: "CTO", value: issue_status_label(cto && cto.status)},
        %{label: "CEO", value: issue_status_label(issue.status)},
        %{label: "Proxy", value: proxy}
      ],
      protocol: protocol_chips(swarm),
      steps: parent_steps(issue, worker_done, worker_total, cto),
      workers: Enum.map(workers, &worker_card(&1, proxy)),
      worker_done: worker_done,
      worker_total: worker_total,
      cto: cto_card(cto, worker_done, worker_total),
      handoff: parent_handoff(issue, cto)
    }
  end

  defp cto_panel(issue, swarm) do
    workers =
      issue
      |> loaded_blockers()
      |> Enum.filter(&swarm_worker?/1)
      |> Enum.sort_by(&worker_index/1)

    worker_done = Enum.count(workers, &closed?/1)
    worker_total = max(length(workers), integer_value(swarm_value(swarm, "agent_count"), 0))
    phase = cto_phase(issue, worker_done, worker_total)
    proxy = proxy_label(swarm)

    %{
      eyebrow: "CTO swarm synthesis",
      phase_label: phase.label,
      phase_state: phase.state,
      summary: cto_summary(phase.key),
      metrics: [
        %{label: "Workers", value: "#{worker_done}/#{worker_total} closed"},
        %{label: "CTO issue", value: issue_status_label(issue.status)},
        %{label: "Role", value: "CTO"},
        %{label: "Proxy", value: proxy}
      ],
      protocol: protocol_chips(swarm),
      steps: cto_steps(issue, worker_done, worker_total),
      workers: Enum.map(workers, &worker_card(&1, proxy)),
      worker_done: worker_done,
      worker_total: worker_total,
      cto: nil,
      handoff: %{
        title: "Prepare CEO restart packet",
        status: issue.status,
        status_label: issue_status_label(issue.status),
        detail: "Close this synthesis with a tagged review so the CEO parent can resume cleanly."
      }
    }
  end

  defp worker_panel(issue, swarm) do
    %{
      eyebrow: "Swarm worker packet",
      phase_label: issue_status_label(issue.status),
      phase_state: if(closed?(issue), do: :complete, else: :active),
      summary: "This packet feeds CTO synthesis before the CEO issue resumes.",
      metrics: [
        %{label: "Role", value: role_label(issue.assigned_role)},
        %{label: "Lens", value: lens_label(issue, swarm) || "Role-specific"},
        %{label: "Harness", value: harness_label(swarm)},
        %{label: "Model", value: swarm_value(swarm, "model") || "runtime default"},
        %{label: "Reasoning", value: swarm_value(swarm, "reasoning_effort") || "auto"},
        %{label: "Proxy", value: swarm_value(swarm, "proxy_profile") || "None"}
      ],
      protocol: protocol_chips(swarm),
      steps: [
        %{
          title: "Worker packet",
          detail: "Capture role-specific assumptions, risks, evidence, and next action.",
          state: if(closed?(issue), do: :complete, else: :active)
        },
        %{
          title: "CTO synthesis",
          detail: "CTO collects this packet before CEO handoff.",
          state: if(closed?(issue), do: :active, else: :waiting)
        },
        %{title: "CEO review", detail: "CEO waits for CTO synthesis.", state: :waiting}
      ],
      workers: [],
      worker_done: 0,
      worker_total: 0,
      cto: nil,
      handoff: nil
    }
  end

  defp parent_steps(issue, worker_done, worker_total, cto) do
    workers_complete? = worker_total > 0 and worker_done >= worker_total
    cto_complete? = cto && closed?(cto)

    [
      %{
        title: "Temporary packets",
        detail: "#{worker_done} of #{worker_total} worker packets are closed.",
        state: if(workers_complete?, do: :complete, else: :active)
      },
      %{
        title: "CTO synthesis",
        detail: cto_step_detail(cto, workers_complete?),
        state: cto_step_state(cto, workers_complete?)
      },
      %{
        title: "CEO handoff",
        detail: ceo_step_detail(issue, cto_complete?),
        state: ceo_step_state(issue, cto_complete?)
      }
    ]
  end

  defp cto_steps(issue, worker_done, worker_total) do
    workers_complete? = worker_total > 0 and worker_done >= worker_total

    [
      %{
        title: "Worker packets",
        detail: "#{worker_done} of #{worker_total} blockers are closed.",
        state: if(workers_complete?, do: :complete, else: :waiting)
      },
      %{
        title: "CTO review",
        detail:
          if(closed?(issue), do: "Synthesis is closed.", else: "Publish the CEO-ready synthesis."),
        state:
          cond do
            closed?(issue) -> :complete
            workers_complete? -> :active
            true -> :waiting
          end
      },
      %{
        title: "CEO restart",
        detail: if(closed?(issue), do: "CEO parent can resume.", else: "Waiting on CTO review."),
        state: if(closed?(issue), do: :complete, else: :waiting)
      }
    ]
  end

  defp parent_phase(issue, worker_done, worker_total, cto) do
    cto_complete? = cto && closed?(cto)
    workers_complete? = worker_total > 0 and worker_done >= worker_total

    cond do
      closed?(issue) ->
        %{key: :closed, label: "Closed", state: :complete}

      cto_complete? ->
        %{key: :ceo_ready, label: "CEO handoff ready", state: :active}

      workers_complete? ->
        %{key: :cto_ready, label: "CTO synthesis ready", state: :active}

      true ->
        %{key: :workers_active, label: "Workers active", state: :waiting}
    end
  end

  defp cto_phase(issue, worker_done, worker_total) do
    workers_complete? = worker_total > 0 and worker_done >= worker_total

    cond do
      closed?(issue) -> %{key: :closed, label: "Synthesis closed", state: :complete}
      workers_complete? -> %{key: :cto_ready, label: "Ready to synthesize", state: :active}
      true -> %{key: :waiting_workers, label: "Waiting on packets", state: :waiting}
    end
  end

  defp parent_summary(:closed), do: "Swarm delivery is closed."

  defp parent_summary(:ceo_ready),
    do: "CTO synthesis is closed; the CEO owns the final owner update."

  defp parent_summary(:cto_ready),
    do: "Temporary packets are closed; CTO synthesis is the next gate."

  defp parent_summary(:workers_active),
    do: "Temporary non-engineering agents are preparing packets before CTO synthesis."

  defp cto_summary(:closed), do: "CTO synthesis is closed and ready for CEO review."

  defp cto_summary(:cto_ready),
    do: "Worker packets are closed; CTO can publish the CEO-ready synthesis."

  defp cto_summary(:waiting_workers),
    do: "CTO synthesis is paused until all worker packets close."

  defp cto_step_detail(nil, _workers_complete?), do: "No CTO synthesis issue found yet."

  defp cto_step_detail(cto, _workers_complete?) when cto.status in [:done, "done"],
    do: "Synthesis is closed."

  defp cto_step_detail(_cto, true), do: "Ready for CTO review."
  defp cto_step_detail(_cto, false), do: "Waiting on worker packets."

  defp cto_step_state(nil, _workers_complete?), do: :waiting
  defp cto_step_state(cto, _workers_complete?) when cto.status in [:done, "done"], do: :complete
  defp cto_step_state(_cto, true), do: :active
  defp cto_step_state(_cto, false), do: :waiting

  defp ceo_step_detail(issue, true), do: "CEO owns #{issue_status_label(issue.status)}."
  defp ceo_step_detail(_issue, false), do: "Waiting for CTO synthesis."

  defp ceo_step_state(issue, true), do: if(closed?(issue), do: :complete, else: :active)
  defp ceo_step_state(_issue, false), do: :waiting

  defp parent_handoff(issue, cto) do
    cto_done? = cto && closed?(cto)

    %{
      title: "CEO owns #{issue.identifier || "this issue"}",
      status: issue.status,
      status_label: issue_status_label(issue.status),
      detail:
        if(cto_done?,
          do: "CTO synthesis is closed; continue with the CEO owner update.",
          else: "CEO waits until the CTO gate closes."
        )
    }
  end

  defp cto_card(nil, _worker_done, _worker_total), do: nil

  defp cto_card(cto, worker_done, worker_total) do
    %{
      id: cto.id,
      title: cto.title,
      identifier: cto.identifier || "CYM-?",
      status: cto.status,
      status_label: issue_status_label(cto.status),
      detail: "#{worker_done}/#{worker_total} worker blockers are closed."
    }
  end

  defp worker_card(issue, inherited_proxy) do
    swarm = swarm_state(issue)
    worker_proxy = swarm_value(swarm, "proxy_profile")

    %{
      id: issue.id,
      title: issue.title,
      identifier: issue.identifier || "CYM-?",
      label: worker_label(worker_index(issue)),
      role: role_label(issue.assigned_role),
      status: issue.status,
      status_label: issue_status_label(issue.status),
      harness: harness_label(swarm),
      model: swarm_value(swarm, "model") || "runtime default",
      reasoning: swarm_value(swarm, "reasoning_effort") || "auto",
      proxy_profile: differing_proxy(worker_proxy, inherited_proxy),
      lens: lens_label(issue, swarm)
    }
  end

  defp differing_proxy(nil, _inherited_proxy), do: nil
  defp differing_proxy(proxy, inherited_proxy) when proxy == inherited_proxy, do: nil
  defp differing_proxy(proxy, _inherited_proxy), do: proxy

  defp harness_label(swarm) do
    case {swarm_value(swarm, "harness"), swarm_value(swarm, "process_preset")} do
      {"process", preset} when is_binary(preset) and preset != "" -> "process:#{preset}"
      {harness, _preset} when is_binary(harness) and harness != "" -> harness
      _ -> "runtime default"
    end
  end

  defp worker_label(index) when is_integer(index) and index > 0, do: "Worker ##{index}"
  defp worker_label(_index), do: "Worker"

  defp swarm_parent?(issue, swarm) do
    truthy?(swarm_value(swarm, "enabled")) and
      issue.origin_type not in ["swarm_worker", "swarm_cto_review"]
  end

  defp swarm_worker?(issue),
    do: issue.origin_type == "swarm_worker" or swarm_worker?(issue, swarm_state(issue))

  defp swarm_worker?(_issue, swarm), do: swarm_value(swarm, "role") == "worker"

  defp swarm_cto?(issue),
    do: issue.origin_type == "swarm_cto_review" or swarm_cto?(issue, swarm_state(issue))

  defp swarm_cto?(_issue, swarm), do: swarm_value(swarm, "role") == "cto_synthesis"

  defp swarm_state(%{monitor_state: monitor_state}) when is_map(monitor_state) do
    case Map.get(monitor_state, "swarm") || Map.get(monitor_state, :swarm) do
      state when is_map(state) -> state
      _ -> %{}
    end
  end

  defp swarm_state(_), do: %{}

  defp swarm_value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, swarm_atom_key(key))

  defp swarm_value(_, _), do: nil

  defp swarm_atom_key("agent_count"), do: :agent_count
  defp swarm_atom_key("enabled"), do: :enabled
  defp swarm_atom_key("harness"), do: :harness
  defp swarm_atom_key("label"), do: :label
  defp swarm_atom_key("lens"), do: :lens
  defp swarm_atom_key("model"), do: :model
  defp swarm_atom_key("name"), do: :name
  defp swarm_atom_key("profile"), do: :profile
  defp swarm_atom_key("process_preset"), do: :process_preset
  defp swarm_atom_key("protocol"), do: :protocol
  defp swarm_atom_key("proxy"), do: :proxy
  defp swarm_atom_key("proxy_profile"), do: :proxy_profile
  defp swarm_atom_key("reasoning_effort"), do: :reasoning_effort
  defp swarm_atom_key("role"), do: :role
  defp swarm_atom_key("rules"), do: :rules
  defp swarm_atom_key("worker_index"), do: :worker_index
  defp swarm_atom_key(_), do: nil

  defp loaded_blockers(%{blocked_by: %Ecto.Association.NotLoaded{}}), do: []
  defp loaded_blockers(%{blocked_by: blockers}) when is_list(blockers), do: blockers
  defp loaded_blockers(_), do: []

  defp worker_index(issue) do
    issue
    |> swarm_state()
    |> swarm_value("worker_index")
    |> integer_value(999)
  end

  defp integer_value(value, _default) when is_integer(value), do: value

  defp integer_value(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> default
    end
  end

  defp integer_value(_, default), do: default

  defp closed?(%{status: status}), do: status in [:done, "done", :cancelled, "cancelled"]
  defp closed?(_), do: false

  defp truthy?(value) when value in [true, "true", 1, "1"], do: true
  defp truthy?(_), do: false

  defp proxy_label(swarm) do
    proxy = swarm_value(swarm, "proxy")
    proxy_pool = swarm_value(proxy, "pool") |> normalize_proxy_pool()

    cond do
      is_map(proxy) and truthy?(swarm_value(proxy, "enabled")) and length(proxy_pool) > 1 ->
        "#{length(proxy_pool)} profiles"

      is_map(proxy) and truthy?(swarm_value(proxy, "enabled")) ->
        swarm_value(proxy, "profile") || "Managed profile"

      is_map(proxy) ->
        "None"

      true ->
        swarm_value(swarm, "proxy_profile") || "None"
    end
  end

  defp normalize_proxy_pool(pool) when is_list(pool), do: Enum.reject(pool, &is_nil/1)
  defp normalize_proxy_pool(_pool), do: []

  defp protocol_chips(swarm) do
    swarm
    |> swarm_value("protocol")
    |> protocol_rule_labels()
    |> case do
      [] -> default_protocol_chips()
      rules -> rules
    end
  end

  defp protocol_rule_labels(protocol) when is_map(protocol) do
    protocol
    |> swarm_value("rules")
    |> List.wrap()
    |> Enum.map(&protocol_rule_label/1)
    |> Enum.reject(&is_nil/1)
  end

  defp protocol_rule_labels(_), do: []

  defp protocol_rule_label(rule) when is_map(rule), do: swarm_value(rule, "label")
  defp protocol_rule_label(rule) when is_binary(rule), do: rule
  defp protocol_rule_label(_), do: nil

  defp default_protocol_chips do
    [
      "Independent first pass",
      "Evidence over consensus",
      "Preserve dissent",
      "CTO synthesis",
      "CEO handoff"
    ]
  end

  defp lens_label(issue, swarm) do
    case swarm_value(swarm_value(swarm, "lens"), "name") do
      name when is_binary(name) and name != "" -> name
      _ -> role_lens_label(issue.assigned_role)
    end
  end

  defp role_lens_label(role) when role in [:product_manager, "product_manager"],
    do: "Market and prioritization"

  defp role_lens_label(role) when role in [:designer, "designer"],
    do: "User journey and usability"

  defp role_lens_label(role) when role in [:researcher, "researcher"],
    do: "Evidence and uncertainty"

  defp role_lens_label(role) when role in [:marketer, "marketer"],
    do: "Positioning and demand"

  defp role_lens_label(role) when role in [:content_strategist, "content_strategist"],
    do: "Narrative and information architecture"

  defp role_lens_label(role) when role in [:sales_development, "sales_development"],
    do: "Buyer objections and qualification"

  defp role_lens_label(role) when role in [:customer_support, "customer_support"],
    do: "Support burden and failure modes"

  defp role_lens_label(_), do: nil

  defp role_label(nil), do: "Worker"
  defp role_label(role), do: Agent.role_label(role)

  defp issue_status_label(nil), do: "Missing"
  defp issue_status_label(:todo), do: "Todo"
  defp issue_status_label("todo"), do: "Todo"
  defp issue_status_label(:in_progress), do: "In progress"
  defp issue_status_label("in_progress"), do: "In progress"
  defp issue_status_label(:in_review), do: "In review"
  defp issue_status_label("in_review"), do: "In review"

  defp issue_status_label(status) do
    status
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp phase_badge_class(:complete),
    do:
      "rounded-full border border-emerald-500/25 bg-emerald-500/10 px-2.5 py-1 text-[11px] font-590 text-emerald-300"

  defp phase_badge_class(:active),
    do:
      "rounded-full border border-brand/25 bg-brand/10 px-2.5 py-1 text-[11px] font-590 text-brand"

  defp phase_badge_class(:waiting),
    do:
      "rounded-full border border-amber-500/25 bg-amber-500/10 px-2.5 py-1 text-[11px] font-590 text-amber-300"

  defp phase_badge_class(_),
    do:
      "rounded-full border border-hairline bg-surface-1 px-2.5 py-1 text-[11px] font-590 text-ink-tertiary"

  defp step_class(:complete),
    do: "rounded-md border border-emerald-500/20 bg-emerald-500/[0.07] px-3 py-2.5"

  defp step_class(:active),
    do: "rounded-md border border-brand/20 bg-brand/[0.08] px-3 py-2.5"

  defp step_class(:waiting),
    do: "rounded-md border border-hairline bg-canvas px-3 py-2.5"

  defp step_class(_), do: step_class(:waiting)

  defp step_dot_class(:complete), do: "h-2 w-2 rounded-full bg-emerald-400"
  defp step_dot_class(:active), do: "h-2 w-2 rounded-full bg-brand"
  defp step_dot_class(:waiting), do: "h-2 w-2 rounded-full bg-amber-300/80"
  defp step_dot_class(_), do: "h-2 w-2 rounded-full bg-ink-tertiary"

  defp status_pill_class(status) when status in [:done, "done"],
    do:
      "shrink-0 rounded-full border border-emerald-500/25 bg-emerald-500/10 px-2 py-0.5 text-[10px] font-590 uppercase text-emerald-300"

  defp status_pill_class(status) when status in [:blocked, "blocked"],
    do:
      "shrink-0 rounded-full border border-amber-500/25 bg-amber-500/10 px-2 py-0.5 text-[10px] font-590 uppercase text-amber-300"

  defp status_pill_class(status) when status in [:todo, "todo"],
    do:
      "shrink-0 rounded-full border border-sky-500/20 bg-sky-500/10 px-2 py-0.5 text-[10px] font-590 uppercase text-sky-300"

  defp status_pill_class(_status),
    do:
      "shrink-0 rounded-full border border-hairline bg-surface-1 px-2 py-0.5 text-[10px] font-590 uppercase text-ink-tertiary"

  defp event_dot_class("success"), do: "h-2 w-2 shrink-0 rounded-full bg-emerald-400"
  defp event_dot_class("warning"), do: "h-2 w-2 shrink-0 rounded-full bg-amber-300"
  defp event_dot_class("error"), do: "h-2 w-2 shrink-0 rounded-full bg-red-400"
  defp event_dot_class(_status), do: "h-2 w-2 shrink-0 rounded-full bg-teal-300"

  defp event_badge_class("success"),
    do:
      "shrink-0 rounded-full border border-emerald-500/25 bg-emerald-500/10 px-2 py-0.5 text-[10px] font-590 uppercase text-emerald-300"

  defp event_badge_class("warning"),
    do:
      "shrink-0 rounded-full border border-amber-500/25 bg-amber-500/10 px-2 py-0.5 text-[10px] font-590 uppercase text-amber-300"

  defp event_badge_class("error"),
    do:
      "shrink-0 rounded-full border border-red-500/25 bg-red-500/10 px-2 py-0.5 text-[10px] font-590 uppercase text-red-300"

  defp event_badge_class(_status),
    do:
      "shrink-0 rounded-full border border-teal-500/25 bg-teal-500/10 px-2 py-0.5 text-[10px] font-590 uppercase text-teal-300"
end
