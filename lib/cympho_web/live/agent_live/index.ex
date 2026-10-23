defmodule CymphoWeb.AgentLive.Index do
  use CymphoWeb, :live_view
  alias Cympho.Agents
  alias Cympho.Agents.Agent
  alias Cympho.Agents.RuntimeEnv
  alias Cympho.BoardApprovals
  alias Cympho.Costs
  alias Cympho.HeartbeatEngine
  alias Cympho.Orchestrator.Dispatcher
  alias Cympho.OrgHealth
  alias Cympho.OwnerAttention
  alias CymphoWeb.AgentLive.Parts
  alias CymphoWeb.Events
  alias CymphoWeb.NextStep
  alias CymphoWeb.TeamRail

  import CymphoWeb.Format, only: [status_pill_class: 1, role_avatar_class: 1]

  # The Team board (plan P6): columns in the owner's words, Idle capped.
  @columns [
    {:stopped, "Stopped", "tb-st"},
    {:waiting, "Waiting on you", "tb-wy"},
    {:working, "Working", "tb-wk"},
    {:idle, "Idle", "tb-id"}
  ]
  @idle_cap 6
  @day_runs 20
  @board_refresh_ms 300
  @agent_events [:agent_paused, :agent_resumed, :agent_terminated]

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket) && socket.assigns[:current_company] do
      Agents.subscribe(socket.assigns.current_company.id)
      # Run starts and ends move agents between Working and Idle.
      Events.subscribe_to_runs(socket.assigns.current_company.id)
    end

    company_id = current_company_id(socket)
    current_agent = session["current_agent"]
    full_agent = scoped_session_agent(current_agent, company_id)

    agents = list_agents(company_id)
    progress = Agents.list_session_progress_by_company(company_id)

    socket =
      assign(socket, :agents, agents)
      |> assign(:current_agent_id, current_agent && current_agent.id)
      |> assign(:current_agent_role, current_agent && current_agent.role)
      |> assign(:current_agent, full_agent)
      |> assign(:status_counts, roster_status_counts(agents, progress))
      |> assign(:org_health, org_health_snapshot(company_id))
      |> assign(:workload, workload_counts(company_id))
      |> assign(:session_progress, progress)
      |> assign(:runtime_enabled?, Dispatcher.enabled?())
      |> assign(:show_all_idle, false)
      |> assign(:board_refresh, nil)
      |> assign_board()

    if connected?(socket) do
      schedule_progress_update()
    end

    {:ok, socket}
  end

  defp schedule_progress_update do
    Process.send_after(self(), :update_progress, 5000)
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, params) do
    socket
    |> assign(:page_title, "Team")
    |> assign(:agent, nil)
    |> assign(:show_all_idle, params["state"] == "idle")
  end

  defp apply_action(socket, nil, params) do
    apply_action(socket, :index, params)
  end

  @impl true
  def handle_info({:agent_created, agent}, socket) do
    {:noreply,
     socket
     |> update(:agents, fn agents -> [agent | agents] end)
     |> refresh_roster_status_counts()
     |> refresh_org_health()
     |> schedule_board()}
  end

  # A pause, resume or termination carries the updated agent, like an update.
  def handle_info({event, %Agent{} = updated_agent}, socket)
      when event == :agent_updated or event in @agent_events do
    {:noreply,
     socket
     |> update(:agents, fn agents ->
       Enum.map(agents, fn agent ->
         if agent.id == updated_agent.id, do: updated_agent, else: agent
       end)
     end)
     |> refresh_roster_status_counts()
     |> refresh_org_health()
     |> schedule_board()}
  end

  def handle_info({:agent_deleted, deleted_id}, socket) do
    {:noreply,
     socket
     |> update(:agents, fn agents ->
       Enum.filter(agents, fn agent -> agent.id != deleted_id end)
     end)
     |> refresh_roster_status_counts()
     |> refresh_org_health()
     |> schedule_board()}
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "run_status"}, socket),
    do: {:noreply, schedule_board(socket)}

  def handle_info({:owner_attention_changed, _company_id}, socket),
    do: {:noreply, schedule_board(socket)}

  def handle_info(:refresh_board, socket),
    do: {:noreply, socket |> assign(:board_refresh, nil) |> assign_board()}

  def handle_info(:update_progress, socket) do
    company_id = current_company_id(socket)
    delegated_progress = Agents.list_session_progress_by_company(company_id)

    running_agents =
      Enum.filter(socket.assigns.agents, fn agent ->
        agent.status == :running and not Map.has_key?(delegated_progress, agent.id)
      end)

    progress =
      running_agents
      |> Enum.map(fn agent ->
        case Agents.get_session_progress(agent.id) do
          {:ok, info} -> {agent.id, info}
          {:error, _} -> {agent.id, nil}
        end
      end)
      |> Enum.into(delegated_progress)

    schedule_progress_update()

    {:noreply,
     socket
     |> assign(:session_progress, progress)
     |> refresh_roster_status_counts()
     |> assign(:workload, workload_counts(current_company_id(socket)))}
  end

  # Anything else on the subscribed topics must never crash the page.
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("delete_agent", %{"id" => id}, socket) do
    case get_scoped_agent(socket, id) do
      {:ok, agent} ->
        {:ok, _} = Agents.delete_agent(agent)
        {:noreply, socket}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Agent not found")}
    end
  end

  def handle_event("kill_session", %{"id" => agent_id}, socket) do
    with {:ok, _agent} <- get_scoped_agent(socket, agent_id),
         :ok <- Agents.kill_session(agent_id) do
      {:noreply,
       socket
       |> update(:session_progress, &Map.delete(&1, agent_id))
       |> refresh_roster_status_counts()
       |> put_flash(:info, "Agent session stopped successfully")}
    else
      {:error, :cleanup_pending} ->
        {:noreply, put_flash(socket, :error, "Session cleanup is still in progress")}

      {:error, :not_running} ->
        {:noreply, put_flash(socket, :error, "Agent is not currently running")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Agent not found")}
    end
  end

  def handle_event("pause_agent", %{"id" => id}, socket) do
    scoped_agent_action(
      socket,
      id,
      &Agents.pause_agent/1,
      "Agent paused successfully",
      "Failed to pause agent"
    )
  end

  def handle_event("resume_agent", %{"id" => id}, socket) do
    scoped_agent_action(
      socket,
      id,
      &Agents.resume_agent/1,
      "Agent resumed successfully",
      "Failed to resume agent"
    )
  end

  def handle_event("terminate_agent", %{"id" => id}, socket) do
    scoped_agent_action(
      socket,
      id,
      &Agents.terminate_agent/1,
      "Agent terminated successfully",
      "Failed to terminate agent"
    )
  end

  def status_dot_class(:running), do: "bg-brand"
  def status_dot_class(:active), do: "bg-success"
  def status_dot_class(:idle), do: "bg-amber-300"
  def status_dot_class(:error), do: "bg-red-400"
  def status_dot_class(status) when status in [:sleeping, :paused], do: "bg-amber-300/60"
  def status_dot_class(_), do: "bg-gray-500"

  def status_label(:idle), do: "Idle"
  def status_label(:running), do: "Running"
  def status_label(:error), do: "Error"
  def status_label(:sleeping), do: "Sleeping"
  def status_label(:offline), do: "Offline"
  def status_label(:active), do: "Active"
  def status_label(:paused), do: "Paused"
  def status_label(:pending_approval), do: "Pending Approval"
  def status_label(:terminated), do: "Terminated"

  def agent_runtime_status(progress, agent) do
    if Map.has_key?(progress || %{}, agent.id), do: :running, else: agent.status
  end

  def role_label(:other), do: "Other"
  def role_label(role), do: Agent.role_label(role)

  def agent_groups(agents) do
    agents
    |> Enum.group_by(&group_key/1)
    |> Enum.sort_by(fn {key, _agents} -> group_rank(key) end)
  end

  @doc """
  One-line summary for a role group header so a manager can skip
  whole groups at a glance: "2 running · 1 needs attention" etc.
  """
  def group_pulse(agents, progress \\ %{}) do
    running = Enum.count(agents, &(agent_runtime_status(progress, &1) == :running))
    stuck = Enum.count(agents, &(&1.status == :error))
    free = Enum.count(agents, &(agent_runtime_status(progress, &1) in [:idle, :active]))

    [
      stuck > 0 && "#{stuck} need#{if stuck == 1, do: "s", else: ""} attention",
      running > 0 && "#{running} running",
      free > 0 && "#{free} free"
    ]
    |> Enum.filter(& &1)
    |> case do
      [] -> "all quiet"
      parts -> Enum.join(parts, " · ")
    end
  end

  def group_needs_attention?(agents), do: Enum.any?(agents, &(&1.status == :error))

  def agent_initials(%{name: name}) when is_binary(name) do
    name
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map(&String.first/1)
    |> Enum.join()
    |> String.upcase()
  end

  def agent_initials(_), do: "?"

  def adapter_label(nil), do: "No adapter"
  def adapter_label(:openai_chat), do: "OpenAI Chat"
  def adapter_label("openai_chat"), do: "OpenAI Chat"

  def adapter_label(adapter) do
    adapter
    |> to_string()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  @doc """
  Label for the adapter every agent shares, or `nil` when the roster mixes them.
  A whole column of the same value says nothing, so the roster states it once
  and drops the column.
  """
  def shared_adapter_label([_, _ | _] = agents) do
    case Enum.uniq_by(agents, &Map.get(&1, :adapter)) do
      [agent] -> adapter_label(Map.get(agent, :adapter))
      _ -> nil
    end
  end

  def shared_adapter_label(_agents), do: nil

  def health_label(status), do: status |> to_string() |> String.replace("_", " ")

  def health_pill_class(:healthy), do: "border-success/25 bg-success/10 text-success"
  def health_pill_class(:degraded), do: "border-amber-500/25 bg-amber-500/10 text-amber-300"
  def health_pill_class(:unavailable), do: "border-brand/25 bg-brand/10 text-brand"
  def health_pill_class(_), do: "border-border bg-surface text-text-secondary"

  def org_health_badge_class(:critical), do: "border-red-500/25 bg-red-500/10 text-red-300"

  def org_health_badge_class(:warning),
    do: "border-amber-500/25 bg-amber-500/10 text-amber-200"

  def org_health_badge_class(:healthy), do: "border-success/25 bg-success/10 text-success"
  def org_health_badge_class(_), do: "border-border bg-surface text-text-secondary"

  def org_metric_tone_class(:critical), do: "border-red-500/20 bg-red-500/[0.08] text-red-200"

  def org_metric_tone_class(:warning),
    do: "border-amber-500/20 bg-amber-500/[0.08] text-amber-100"

  def org_metric_tone_class(:healthy), do: "border-success/20 bg-success/[0.08] text-success"
  def org_metric_tone_class(_), do: "border-border bg-panel text-text-secondary"

  def format_heartbeat(%{last_heartbeat_at: nil}), do: "Never"

  def format_heartbeat(%{last_heartbeat_at: datetime}),
    do: Calendar.strftime(datetime, "%b %d, %H:%M")

  def format_heartbeat(_), do: "Never"

  def show_spawn_button?(%Agents.Agent{} = agent) do
    Agents.spawnable_roles(agent) |> length() > 1
  end

  def show_spawn_button?(_), do: false

  def runtime_command(%{adapter: adapter} = agent)
      when adapter in [:claude_code, "claude_code"] do
    runtime_config_value(agent, "command") ||
      Application.get_env(:cympho, :claude_code_command) ||
      System.get_env("CYMPHO_CLAUDE_COMMAND") ||
      "claude"
  end

  def runtime_command(%{adapter: adapter}) when adapter in [:codex, "codex"], do: "codex"

  def runtime_command(%{adapter: adapter} = agent) when adapter in [:agrenting, "agrenting"] do
    case runtime_config_value(agent, "agent_did") || config_value(agent, "agent_did") do
      nil -> "Agrenting remote"
      did -> "Agrenting - #{did}"
    end
  end

  def runtime_command(%{adapter: adapter} = agent)
      when adapter in [:cursor, "cursor", :process, "process"] do
    runtime_config_value(agent, "command") || adapter_label(adapter)
  end

  def runtime_command(%{adapter: adapter}), do: adapter_label(adapter)
  def runtime_command(_), do: "No runtime"

  def runtime_model(%{adapter: adapter} = agent)
      when adapter in [
             :codex,
             "codex",
             :cursor,
             "cursor",
             :openai_chat,
             "openai_chat",
             :openclaw,
             "openclaw",
             :process,
             "process",
             :agrenting,
             "agrenting"
           ] do
    runtime_config_value(agent, "model") ||
      default_runtime_model(adapter, agent)
  end

  # Returns nil when the agent runs on the adapter default; the row then prints
  # nothing instead of repeating "No model override".
  def runtime_model(agent) do
    env = RuntimeEnv.from_agent(agent)

    env["ANTHROPIC_MODEL"] ||
      env["ANTHROPIC_DEFAULT_SONNET_MODEL"] ||
      env["OPENAI_MODEL"] ||
      env["MODEL"]
  end

  defp default_runtime_model(adapter, _agent) when adapter in [:codex, "codex"],
    do: Cympho.Adapters.CodexAdapter.default_model()

  defp default_runtime_model(adapter, _agent) when adapter in [:cursor, "cursor"],
    do: Cympho.Adapters.RuntimeOptions.cursor_default_model()

  defp default_runtime_model(adapter, _agent) when adapter in [:openai_chat, "openai_chat"],
    do: "qwen3.7-plus"

  defp default_runtime_model(adapter, agent) when adapter in [:openclaw, "openclaw"] do
    provider =
      runtime_config_value(agent, "provider") ||
        Cympho.Adapters.RuntimeOptions.openclaw_default_provider()

    Cympho.Adapters.RuntimeOptions.openclaw_default_model(provider)
  end

  defp default_runtime_model(_adapter, _agent), do: nil

  defp config_value(%{config: config}, key) when is_map(config), do: config[key]
  defp config_value(_, _), do: nil

  def format_elapsed(seconds) when is_integer(seconds) do
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)
    secs = rem(seconds, 60)

    if hours > 0 do
      "#{hours}h #{minutes}m #{secs}s"
    else
      "#{minutes}m #{secs}s"
    end
  end

  def format_elapsed(_), do: "0s"

  defp current_company_id(socket) do
    socket.assigns[:current_company] && socket.assigns.current_company.id
  end

  defp list_agents(nil), do: Agents.list_agents()
  defp list_agents(company_id), do: Agents.list_agents_by_company(company_id)

  defp roster_status_counts(agents, progress) do
    Enum.reduce(agents, %{}, fn agent, counts ->
      Map.update(counts, agent_runtime_status(progress, agent), 1, &(&1 + 1))
    end)
  end

  defp refresh_roster_status_counts(socket) do
    assign(
      socket,
      :status_counts,
      roster_status_counts(socket.assigns.agents, socket.assigns.session_progress)
    )
  end

  defp org_health_snapshot(nil), do: OrgHealth.snapshot(nil)
  defp org_health_snapshot(company_id), do: OrgHealth.snapshot(company_id)

  defp workload_counts(nil), do: %{}
  defp workload_counts(company_id), do: Agents.count_active_assignments_by_company(company_id)

  def workload_for(workload, agent_id), do: Map.get(workload || %{}, agent_id, 0)

  def workload_tone(active, max_jobs) do
    cond do
      is_integer(max_jobs) and max_jobs > 0 and active >= max_jobs ->
        "border-amber-500/30 bg-amber-500/10 text-amber-200"

      active > 0 ->
        "border-border bg-panel text-text-secondary"

      true ->
        "border-border bg-panel text-text-quaternary"
    end
  end

  defp refresh_org_health(socket) do
    assign(socket, :org_health, org_health_snapshot(current_company_id(socket)))
  end

  ## ── The r3 Team page (plan P6) ────────────────────────────────

  def board_columns, do: @columns
  def idle_cap, do: @idle_cap

  def ac_word_class(:stopped), do: "c-stop"
  def ac_word_class(:working), do: "c-work"
  def ac_word_class(_kind), do: nil

  # The proposed agent's name (the agent_hire executor's attrs), else the vote's title.
  def hire_name(%{proposal_data: %{"attrs" => %{"name" => name}}}) when is_binary(name), do: name
  def hire_name(%{title: title}), do: title

  # Bursts of agent and run messages redraw the board once.
  defp schedule_board(%{assigns: %{board_refresh: nil}} = socket) do
    assign(socket, :board_refresh, Process.send_after(self(), :refresh_board, @board_refresh_ms))
  end

  defp schedule_board(socket), do: socket

  defp reload_board(socket) do
    socket
    |> assign(:agents, list_agents(current_company_id(socket)))
    |> refresh_roster_status_counts()
    |> assign_board()
  end

  # The Next step (a company stopped at its limit, else a stopped agent), the
  # board, the proposed hires and the last day's runs. Company-scoped reads.
  defp assign_board(socket) do
    case current_company_id(socket) do
      nil ->
        assign(socket,
          next_item: nil,
          board: Map.new(@columns, fn {col, _label, _id} -> {col, []} end),
          team_size: 0,
          hires: [],
          runs_24h: 0,
          day_runs: [],
          agent_names: %{},
          spending: nil
        )

      company_id ->
        user = socket.assigns[:current_user]
        agents = socket.assigns.agents
        items = company_id |> OwnerAttention.list_items(user) |> OwnerAttention.owner_order()
        since = DateTime.add(DateTime.utc_now(), -86_400, :second)
        names = Map.new(agents, &{&1.id, &1.name})

        assign(socket,
          next_item:
            Enum.find(items, &(OwnerAttention.owner_kind(&1) == :stopped)) ||
              Enum.find(items, &(&1.kind == :agent_paused)),
          board: board(company_id, user, agents, items),
          team_size: Enum.count(agents, &(not terminated?(&1))),
          hires:
            BoardApprovals.list_board_approvals(%{
              company_id: company_id,
              status: "pending",
              category: "agent_hire"
            }),
          runs_24h: HeartbeatEngine.count_runs_since(company_id, since),
          day_runs:
            company_id
            |> HeartbeatEngine.list_runs_since(since, limit: @day_runs)
            |> Enum.map(&day_run_row(&1, names)),
          agent_names: names,
          spending: TeamRail.spending(company_id)
        )
    end
  end

  defp board(company_id, user, agents, items) do
    for_you = TeamRail.for_you_counts(company_id, user)
    runs = HeartbeatEngine.latest_runs_by_agent(company_id)

    costs =
      company_id
      |> Costs.by_agent(30, max(length(agents), 1))
      |> Map.new(&{&1.agent_id, &1.total_cost})

    # The first owner item per agent, in the owner's order, names what it waits on.
    first_items =
      items
      |> Enum.reverse()
      |> Map.new(&{Parts.for_you_agent_id(&1), &1})

    agents
    |> Enum.reject(&terminated?/1)
    |> Enum.map(
      &card(&1, runs[&1.id], Map.get(for_you, &1.id, 0), first_items[&1.id], costs[&1.id])
    )
    |> Enum.group_by(& &1.col)
    |> then(fn groups ->
      Map.new(@columns, fn {col, _label, _id} ->
        {col, groups |> Map.get(col, []) |> Enum.sort_by(&card_rank/1)}
      end)
    end)
  end

  defp card(agent, run, for_you, item, cost) do
    running? = match?(%{status: "running"}, run)
    {kind, word} = Parts.status(agent, running?)

    col =
      cond do
        kind == :stopped -> :stopped
        kind == :working -> :working
        kind == :waiting or for_you > 0 -> :waiting
        true -> :idle
      end

    %{
      id: agent.id,
      name: agent.name,
      initials: Parts.initials(agent.name),
      role: role_label(agent.role),
      kind: kind,
      word: word,
      line: line_parts(now_or_last(kind, run, item)),
      cost: Parts.usd(cost),
      for_you: for_you,
      col: col
    }
  end

  defp line_parts({_text, _minutes} = line), do: line
  defp line_parts(text), do: {text, nil}

  # Waiting on you: most for-you items first; every column then by name.
  defp card_rank(%{col: :waiting} = card), do: {-card.for_you, String.downcase(card.name)}
  defp card_rank(card), do: {0, String.downcase(card.name)}

  defp terminated?(agent),
    do: agent.status == :terminated or agent.governance_status == "terminated"

  # What the agent is doing now (with its minutes, drawn mono), else what it is
  # waiting on you for, else what it did last; at most six words (build-spec §6).
  defp now_or_last(:working, %{status: "running"} = run, _item) do
    minutes = if run.started_at, do: DateTime.diff(DateTime.utc_now(), run.started_at, :minute)
    {run_subject(run.issue), minutes && "#{minutes} min"}
  end

  defp now_or_last(_kind, _run, %{kind: :interaction, issue: %{identifier: id}}),
    do: "asked you on #{id}"

  defp now_or_last(_kind, _run, %{kind: :review_queue, issue: %{identifier: id}}),
    do: "#{id} ready for your review"

  defp now_or_last(_kind, _run, %{kind: kind}) when kind in [:approval, :board_approval],
    do: "asked for your approval"

  defp now_or_last(_kind, nil, _item), do: "no runs yet"
  defp now_or_last(_kind, %{issue: nil} = run, _item), do: "last run at #{run_clock(run)}"

  defp now_or_last(_kind, %{issue: %{status: :done} = issue} = run, _item) do
    if finished_by?(issue, run),
      do: "finished #{issue.identifier} at #{run_clock(run)}",
      else: "last on #{issue.identifier}"
  end

  defp now_or_last(_kind, %{issue: %{status: :in_review, identifier: id}}, _item),
    do: "#{id} in team review"

  defp now_or_last(_kind, %{issue: %{identifier: id}}, _item), do: "last on #{id}"

  defp run_subject(%{status: :in_review, identifier: id}) when is_binary(id),
    do: "reviewing #{id}"

  defp run_subject(%{identifier: id}) when is_binary(id), do: "on #{id}"
  defp run_subject(_issue), do: "working"

  # The task was completed during or after this run, not before it.
  defp finished_by?(%{completed_at: %DateTime{} = done}, %{started_at: %DateTime{} = started}),
    do: DateTime.compare(done, started) != :lt

  defp finished_by?(_issue, _run), do: false

  defp run_clock(run) do
    case run.completed_at || run.started_at || run.inserted_at do
      %DateTime{} = at -> Calendar.strftime(at, "%H:%M")
      _ -> "?"
    end
  end

  defp day_run_row(run, names) do
    name = Map.get(names, run.agent_id) || (run.agent && run.agent.name) || "An agent"
    subject = if run.issue, do: " on #{run.issue.identifier}", else: ""

    Parts.run_row(run, name <> subject, "/agents/#{run.agent_id}?tab=runs&run_id=#{run.id}")
  end

  defp get_scoped_agent(socket, id) do
    case current_company_id(socket) do
      nil -> {:error, :not_found}
      company_id -> Agents.get_company_agent(company_id, id)
    end
  end

  defp scoped_agent_action(socket, id, action, success_message, error_message) do
    with {:ok, agent} <- get_scoped_agent(socket, id),
         {:ok, _agent} <- action.(agent) do
      {:noreply, socket |> put_flash(:info, success_message) |> reload_board()}
    else
      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Agent not found")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, error_message)}
    end
  end

  defp scoped_session_agent(nil, _company_id), do: nil

  defp scoped_session_agent(%{id: id}, company_id) when is_binary(company_id) do
    case Agents.get_company_agent(company_id, id) do
      {:ok, agent} -> agent
      {:error, _} -> nil
    end
  end

  defp scoped_session_agent(%{id: id}, nil) do
    case Agents.get_agent(id) do
      {:ok, agent} -> agent
      {:error, _} -> nil
    end
  end

  defp runtime_config_value(%{runtime_config: runtime_config, config: config}, key) do
    Map.get(runtime_config || %{}, key) ||
      Map.get(runtime_config || %{}, String.to_atom(key)) ||
      Map.get(config || %{}, key) ||
      Map.get(config || %{}, String.to_atom(key))
  end

  defp first_staffing_gap_label(%{role_demand_gaps: [gap | _]}), do: "Hire #{gap.label}"
  defp first_staffing_gap_label(_), do: "Hire role"

  defp new_agent_query_for_gap(gap) do
    %{
      role: to_string(gap.role),
      name: gap.label,
      runtime_profile_id: "openai-chat-qwen-dashscope-flash",
      return_to: "/agents#agent-role-coverage"
    }
    |> maybe_put_parent_query(gap.suggested_parent)
  end

  defp maybe_put_parent_query(query, %{id: id}) when is_binary(id),
    do: Map.put(query, :parent_id, id)

  defp maybe_put_parent_query(query, _), do: query

  defp issue_example_label(%{identifier: identifier, title: title})
       when is_binary(identifier) and identifier != "" do
    "#{identifier} · #{title}"
  end

  defp issue_example_label(%{title: title}), do: title || "Untitled issue"

  defp plural_noun(1, singular), do: singular
  defp plural_noun(_count, singular), do: singular <> "s"

  @doc """
  Orders agents inside a role group so what needs a human lands first:
  stuck, then working, then free, then everything asleep or gone.
  """
  def sort_group(agents) do
    Enum.sort_by(agents, fn agent -> {status_rank(agent.status), agent.name || ""} end)
  end

  defp status_rank(:error), do: 0
  defp status_rank(:running), do: 1
  defp status_rank(:active), do: 2
  defp status_rank(:idle), do: 3
  defp status_rank(:pending_approval), do: 4
  defp status_rank(status) when status in [:sleeping, :paused], do: 5
  defp status_rank(_), do: 6

  def session_progress_note(progress, agent_id) do
    case Map.get(progress || %{}, agent_id) do
      %{issue: %{identifier: identifier}, elapsed_seconds: elapsed}
      when is_binary(identifier) ->
        "on #{identifier} · #{format_elapsed(elapsed)}"

      %{elapsed_seconds: elapsed} when is_integer(elapsed) and elapsed > 0 ->
        "working · #{format_elapsed(elapsed)}"

      _ ->
        nil
    end
  end

  defp group_key(%{role: role}) do
    if role in Agent.role_options(), do: role, else: :other
  end

  defp group_key(_), do: :other

  defp group_rank(role) do
    Enum.find_index(Agent.role_options(), &(&1 == role)) || length(Agent.role_options())
  end
end
