defmodule CymphoWeb.AgentLive.Index do
  use CymphoWeb, :live_view
  alias Cympho.Agents
  alias Cympho.Agents.Agent
  alias Cympho.Agents.RuntimeEnv
  alias Cympho.OrgHealth

  import CymphoWeb.Format, only: [status_pill_class: 1, role_avatar_class: 1]

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket) && socket.assigns[:current_company] do
      Agents.subscribe(socket.assigns.current_company.id)
    end

    company_id = current_company_id(socket)
    current_agent = session["current_agent"]
    full_agent = scoped_session_agent(current_agent, company_id)

    socket =
      assign(socket, :agents, list_agents(company_id))
      |> assign(:current_agent_id, current_agent && current_agent.id)
      |> assign(:current_agent_role, current_agent && current_agent.role)
      |> assign(:current_agent, full_agent)
      |> assign(:status_counts, status_counts(company_id))
      |> assign(:org_health, org_health_snapshot(company_id))
      |> assign(:workload, workload_counts(company_id))
      |> assign(:session_progress, %{})

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

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Agents")
    |> assign(:agent, nil)
  end

  defp apply_action(socket, nil, params) do
    apply_action(socket, :index, params)
  end

  @impl true
  def handle_info({:agent_created, agent}, socket) do
    {:noreply,
     socket
     |> update(:agents, fn agents -> [agent | agents] end)
     |> update(:status_counts, fn counts ->
       Map.update(counts, agent.status, 1, &(&1 + 1))
     end)
     |> refresh_org_health()}
  end

  def handle_info({:agent_updated, updated_agent}, socket) do
    old_agent = Enum.find(socket.assigns.agents, fn a -> a.id == updated_agent.id end)
    old_status = old_agent && old_agent.status

    {:noreply,
     socket
     |> update(:agents, fn agents ->
       Enum.map(agents, fn agent ->
         if agent.id == updated_agent.id, do: updated_agent, else: agent
       end)
     end)
     |> update(:status_counts, fn counts ->
       if old_status && old_status != updated_agent.status do
         counts
         |> Map.update(old_status, 0, &(&1 - 1))
         |> Map.update(updated_agent.status, 0, &(&1 + 1))
       else
         counts
       end
     end)
     |> refresh_org_health()}
  end

  def handle_info({:agent_deleted, deleted_id}, socket) do
    deleted_agent = Enum.find(socket.assigns.agents, fn a -> a.id == deleted_id end)
    status = deleted_agent && deleted_agent.status

    {:noreply,
     socket
     |> update(:agents, fn agents ->
       Enum.filter(agents, fn agent -> agent.id != deleted_id end)
     end)
     |> update(:status_counts, fn counts ->
       if status do
         Map.update(counts, status, 0, &(&1 - 1))
       else
         counts
       end
     end)
     |> refresh_org_health()}
  end

  def handle_info(:update_progress, socket) do
    running_agents = Enum.filter(socket.assigns.agents, fn a -> a.status == :running end)

    progress =
      running_agents
      |> Enum.map(fn agent ->
        case Agents.get_session_progress(agent.id) do
          {:ok, info} -> {agent.id, info}
          {:error, _} -> {agent.id, nil}
        end
      end)
      |> Enum.into(%{})

    schedule_progress_update()

    {:noreply,
     socket
     |> assign(:session_progress, progress)
     |> assign(:workload, workload_counts(current_company_id(socket)))}
  end

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
      {:noreply, put_flash(socket, :info, "Agent session stopped successfully")}
    else
      {:error, :not_running} ->
        {:noreply, put_flash(socket, :error, "Agent is not currently running")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Agent not found")}
    end
  end

  def handle_event("pause_agent", %{"id" => id}, socket) do
    case Agents.pause_agent(id) do
      {:ok, _agent} ->
        {:noreply, put_flash(socket, :info, "Agent paused successfully")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to pause agent")}
    end
  end

  def handle_event("resume_agent", %{"id" => id}, socket) do
    case Agents.resume_agent(id) do
      {:ok, _agent} ->
        {:noreply, put_flash(socket, :info, "Agent resumed successfully")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to resume agent")}
    end
  end

  def handle_event("terminate_agent", %{"id" => id}, socket) do
    case Agents.terminate_agent(id) do
      {:ok, _agent} ->
        {:noreply, put_flash(socket, :info, "Agent terminated successfully")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to terminate agent")}
    end
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
  def group_pulse(agents) do
    running = Enum.count(agents, &(&1.status == :running))
    stuck = Enum.count(agents, &(&1.status == :error))
    free = Enum.count(agents, &(&1.status in [:idle, :active]))

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

  defp status_counts(nil), do: Agents.count_by_status()
  defp status_counts(company_id), do: Agents.count_by_status(company_id)

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

  defp get_scoped_agent(socket, id) do
    case current_company_id(socket) do
      nil -> Agents.get_agent(id)
      company_id -> Agents.get_company_agent(company_id, id)
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

  def agents_needing_attention(agents) do
    agents |> Enum.filter(&(&1.status == :error)) |> Enum.sort_by(&(&1.name || ""))
  end

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
