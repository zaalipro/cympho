defmodule CymphoWeb.AgentLive.Show do
  use CymphoWeb, :live_view

  alias Cympho.Agents
  alias Cympho.Agents.Agent
  alias Cympho.Agents.InstructionFiles
  alias Cympho.Agents.RuntimeEnv
  alias Cympho.HeartbeatEngine
  alias Cympho.Issues
  alias Cympho.Plugins
  alias Cympho.Skills
  alias Cympho.Wakes
  alias CymphoWeb.Markdown

  import CymphoWeb.Format,
    only: [format_datetime: 1, role_avatar_class: 1, status_pill_class: 1]

  @valid_tabs ~w(dashboard instructions skills configuration runs)
  @entry_file "AGENTS.md"

  @impl true
  def mount(%{"id" => "new"}, _session, socket) do
    {:ok, push_navigate(socket, to: ~p"/agents")}
  end

  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket) && socket.assigns[:current_company] do
      Agents.subscribe(socket.assigns.current_company.id)
    end

    case Agents.get_agent(id) do
      {:ok, agent} ->
        {:ok, assign_agent(socket, agent)}

      {:error, :not_found} ->
        {:ok, push_navigate(socket, to: ~p"/agents")}
    end
  end

  @impl true
  def handle_params(%{"id" => id} = params, _url, socket) do
    tab = parse_tab(params["tab"])
    file = params["file"]
    run_id = params["run_id"]

    socket =
      case Agents.get_agent(id) do
        {:ok, agent} ->
          socket
          |> assign(:page_title, agent.name)
          |> assign(:current_tab, tab)
          |> assign_agent(agent)
          |> maybe_select_file(file)
          |> maybe_select_run(run_id)

        {:error, :not_found} ->
          socket
          |> put_flash(:error, "Agent not found")
          |> push_navigate(to: ~p"/agents")
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("set_tab", %{"tab" => tab}, socket) do
    tab = parse_tab(tab)

    {:noreply,
     socket
     |> assign(:current_tab, tab)
     |> push_patch(to: ~p"/agents/#{socket.assigns.agent.id}?tab=#{tab}")}
  end

  # ── Configuration tab — edit form ──────────────────────────────────────

  def handle_event("config_validate", %{"agent" => agent_params} = params, socket) do
    env_rows = env_rows_from_params(params, socket.assigns.env_rows)
    permissions = permissions_from_params(params, socket.assigns.permissions)

    full_params =
      agent_params
      |> Map.put("runtime_config", build_runtime_config(socket.assigns.agent, env_rows))
      |> Map.put("permissions", permissions)

    changeset =
      socket.assigns.agent
      |> Agents.change_agent(normalize_agent_params(full_params))
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:env_rows, env_rows)
     |> assign(:permissions, permissions)
     |> assign(:form, to_form(changeset))}
  end

  def handle_event("config_save", %{"agent" => agent_params} = params, socket) do
    env_rows = env_rows_from_params(params, socket.assigns.env_rows)
    permissions = permissions_from_params(params, socket.assigns.permissions)

    full_params =
      agent_params
      |> Map.put("runtime_config", build_runtime_config(socket.assigns.agent, env_rows))
      |> Map.put("permissions", permissions)

    case Agents.update_agent(socket.assigns.agent, normalize_agent_params(full_params)) do
      {:ok, agent} ->
        {:noreply,
         socket
         |> put_flash(:info, "Configuration saved.")
         |> assign_agent(agent)}

      {:error, :pending_board_approval, approval_id} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "Change requires board approval. Request submitted (##{String.slice(approval_id, 0, 8)})."
         )}

      {:error, changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Could not save configuration.")
         |> assign(:env_rows, env_rows)
         |> assign(:permissions, permissions)
         |> assign(:form, to_form(Map.put(changeset, :action, :update)))}
    end
  end

  def handle_event("add_env_row", _params, socket) do
    rows = socket.assigns.env_rows ++ [%{key: "", value: ""}]
    {:noreply, assign(socket, :env_rows, rows)}
  end

  def handle_event("remove_env_row", %{"index" => index}, socket) do
    idx = String.to_integer(index)
    rows = List.delete_at(socket.assigns.env_rows, idx)
    rows = if rows == [], do: [%{key: "", value: ""}], else: rows
    {:noreply, assign(socket, :env_rows, rows)}
  end

  def handle_event("toggle_permission", %{"key" => key}, socket) do
    current = !!Map.get(socket.assigns.permissions, key, false)
    permissions = Map.put(socket.assigns.permissions, key, !current)
    {:noreply, assign(socket, :permissions, permissions)}
  end

  # ── Instructions tab — multi-file ─────────────────────────────────────

  def handle_event("select_file", %{"file" => file}, socket) do
    socket = maybe_select_file(socket, file)

    {:noreply,
     push_patch(socket,
       to: ~p"/agents/#{socket.assigns.agent.id}?tab=instructions&file=#{file}"
     )}
  end

  def handle_event("new_file", %{"name" => name}, socket) do
    name = String.trim(name)
    agent = socket.assigns.agent

    cond do
      name == "" ->
        {:noreply, put_flash(socket, :error, "File name cannot be empty.")}

      name == @entry_file ->
        {:noreply, put_flash(socket, :error, "AGENTS.md is the entry file and already exists.")}

      InstructionFiles.exists?(agent, name) ->
        {:noreply, put_flash(socket, :error, "A file named #{name} already exists.")}

      true ->
        case InstructionFiles.create(agent, name, "") do
          {:ok, _file} ->
            {:ok, agent} = Agents.get_agent(agent.id)

            socket =
              socket
              |> assign_agent(agent)
              |> maybe_select_file(name)

            {:noreply,
             push_patch(socket, to: ~p"/agents/#{agent.id}?tab=instructions&file=#{name}")}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Could not create file.")}
        end
    end
  end

  def handle_event("delete_file", %{"file" => file}, socket) when file != @entry_file do
    case InstructionFiles.delete(socket.assigns.agent, file) do
      {:ok, _} ->
        {:ok, agent} = Agents.get_agent(socket.assigns.agent.id)

        {:noreply,
         socket
         |> put_flash(:info, "Deleted #{file}.")
         |> assign_agent(agent)
         |> maybe_select_file(@entry_file)}

      _ ->
        {:noreply, put_flash(socket, :error, "Could not delete file.")}
    end
  end

  def handle_event("delete_file", _, socket), do: {:noreply, socket}

  def handle_event("save_file", %{"content" => content}, socket) do
    file = socket.assigns.selected_file

    case InstructionFiles.upsert_content(socket.assigns.agent, file, content) do
      {:ok, _} ->
        {:ok, agent} = Agents.get_agent(socket.assigns.agent.id)

        {:noreply,
         socket
         |> put_flash(:info, "Saved #{file}.")
         |> assign_agent(agent)
         |> maybe_select_file(file)}

      _ ->
        {:noreply, put_flash(socket, :error, "Save failed.")}
    end
  end

  def handle_event("toggle_instructions_preview", _params, socket) do
    {:noreply, assign(socket, :instructions_preview?, !socket.assigns.instructions_preview?)}
  end

  # ── Skills tab ────────────────────────────────────────────────────────

  def handle_event("toggle_skill", %{"plugin_id" => plugin_id}, socket) do
    agent_id = socket.assigns.agent.id

    if MapSet.member?(socket.assigns.assigned_skill_ids, plugin_id) do
      _ = Skills.remove_skill_from_agent(agent_id, plugin_id)
    else
      _ = Skills.assign_skill_to_agent(agent_id, plugin_id)
    end

    {:noreply, refresh_skills(socket)}
  end

  # ── Runs tab ──────────────────────────────────────────────────────────

  def handle_event("select_run", %{"run_id" => run_id}, socket) do
    socket = maybe_select_run(socket, run_id)

    {:noreply,
     push_patch(socket, to: ~p"/agents/#{socket.assigns.agent.id}?tab=runs&run_id=#{run_id}")}
  end

  # ── Top action bar ────────────────────────────────────────────────────

  def handle_event("pause_agent", _params, socket) do
    case Agents.pause_agent(socket.assigns.agent) do
      {:ok, agent} ->
        {:noreply,
         socket
         |> put_flash(:info, "Agent paused.")
         |> assign_agent(agent)}

      _ ->
        {:noreply, put_flash(socket, :error, "Could not pause agent.")}
    end
  end

  def handle_event("resume_agent", _params, socket) do
    case Agents.resume_agent(socket.assigns.agent) do
      {:ok, agent} ->
        {:noreply,
         socket
         |> put_flash(:info, "Agent resumed.")
         |> assign_agent(agent)}

      _ ->
        {:noreply, put_flash(socket, :error, "Could not resume agent.")}
    end
  end

  @impl true
  def handle_info({:agent_updated, updated_agent}, socket) do
    if socket.assigns.agent.id == updated_agent.id do
      {:noreply, assign_agent(socket, updated_agent)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:agent_deleted, _deleted_id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/agents")}
  end

  # ── Loading helpers ───────────────────────────────────────────────────

  defp assign_agent(socket, agent) do
    agent = Cympho.Repo.preload(agent, [:parent, :children])
    wake_history = Wakes.list_agent_wakes(agent.id)
    runs = HeartbeatEngine.list_runs_for_agent(agent.id, limit: 30)
    recent_issues = Issues.list_recent_for_agent(agent.id, 10)
    env_vars = RuntimeEnv.from_agent(agent)
    changeset = Agents.change_agent(agent)

    socket
    |> assign(:agent, agent)
    |> assign(:wake_history, wake_history)
    |> assign(:recent_runs, runs)
    |> assign(:latest_run, List.first(runs))
    |> assign(:recent_issues, recent_issues)
    |> assign(:env_vars, env_vars)
    |> assign(:env_rows, env_rows_from(agent))
    |> assign(:permissions, normalise_permissions(agent.permissions))
    |> assign(:instructions_preview?, false)
    |> assign(:form, to_form(changeset))
    |> assign(:reports_to_options, reports_to_options(socket.assigns[:current_company], agent.id))
    |> refresh_skills()
    |> maybe_default_tab()
  end

  defp refresh_skills(socket) do
    company_id = socket.assigns[:current_company] && socket.assigns.current_company.id
    plugins = if company_id, do: Plugins.list_plugins(company_id: company_id), else: []
    assigned = Skills.list_skills_for_agent(socket.assigns.agent.id)
    assigned_ids = MapSet.new(assigned, & &1.id)

    socket
    |> assign(:plugins, plugins)
    |> assign(:assigned_skill_ids, assigned_ids)
  end

  defp maybe_default_tab(socket) do
    if socket.assigns[:current_tab], do: socket, else: assign(socket, :current_tab, "dashboard")
  end

  defp maybe_select_file(socket, nil), do: maybe_select_file(socket, @entry_file)
  defp maybe_select_file(socket, ""), do: maybe_select_file(socket, @entry_file)

  defp maybe_select_file(socket, file) do
    files = file_list(socket.assigns.agent)
    file = if file in files, do: file, else: @entry_file

    socket
    |> assign(:selected_file, file)
    |> assign(:selected_file_content, file_content(socket.assigns.agent, file))
    |> assign(:files, files)
  end

  defp maybe_select_run(socket, nil) do
    run = List.first(socket.assigns.recent_runs || [])
    assign(socket, :selected_run, run)
  end

  defp maybe_select_run(socket, run_id) do
    run = Enum.find(socket.assigns.recent_runs || [], &(&1.id == run_id))
    assign(socket, :selected_run, run || List.first(socket.assigns.recent_runs || []))
  end

  defp parse_tab(tab) when tab in @valid_tabs, do: tab
  defp parse_tab(_), do: "dashboard"

  defp file_list(%Agent{} = agent) do
    InstructionFiles.list_for_agent(agent)
    |> Enum.map(fn {filename, _content} -> filename end)
  end

  defp file_content(%Agent{} = agent, file) do
    InstructionFiles.get_content(agent, file) || ""
  end

  # ── Configuration form helpers ────────────────────────────────────────

  defp normalize_agent_params(params) do
    params
    |> Map.update("adapter", "claude_code", &normalize_adapter/1)
    |> normalize_parent_id()
  end

  defp normalize_parent_id(params) do
    case Map.get(params, "parent_id") do
      "" -> Map.put(params, "parent_id", nil)
      _ -> params
    end
  end

  defp env_rows_from(%Agent{} = agent) do
    case RuntimeEnv.from_agent(agent) do
      env when map_size(env) == 0 ->
        [%{key: "", value: ""}]

      env ->
        env
        |> Enum.sort_by(fn {k, _} -> k end)
        |> Enum.map(fn {k, v} -> %{key: k, value: v} end)
    end
  end

  defp env_rows_from_params(params, fallback) do
    case params do
      %{"env_keys" => keys, "env_values" => values}
      when is_map(keys) and is_map(values) ->
        indices = keys |> Map.keys() |> Enum.sort_by(&safe_to_int/1)
        Enum.map(indices, fn i -> %{key: keys[i] || "", value: values[i] || ""} end)

      _ ->
        fallback
    end
  end

  defp safe_to_int(s) when is_binary(s), do: String.to_integer(s)
  defp safe_to_int(s), do: s

  defp build_runtime_config(%Agent{runtime_config: existing}, rows) do
    env =
      rows
      |> Enum.reject(fn %{key: k} -> String.trim(k) == "" end)
      |> Enum.reduce(%{}, fn %{key: k, value: v}, acc -> Map.put(acc, String.trim(k), v) end)

    (existing || %{})
    |> Map.put("env", env)
  end

  defp permissions_from_params(%{"permissions" => params}, fallback) when is_map(params) do
    Map.merge(fallback, Map.new(params, fn {k, v} -> {to_string(k), truthy?(v)} end))
  end

  defp permissions_from_params(_params, fallback), do: fallback

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?("on"), do: true
  defp truthy?(_), do: false

  defp normalise_permissions(nil), do: %{}

  defp normalise_permissions(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), !!v} end)
  end

  defp reports_to_options(%{id: company_id}, exclude_id) do
    company_id
    |> Agents.list_agents_by_company()
    |> Enum.reject(&(&1.id == exclude_id))
    |> Enum.map(fn agent ->
      label = if agent.title, do: "#{agent.name} · #{agent.title}", else: agent.name
      {label, agent.id}
    end)
    |> then(&[{"— No manager —", ""} | &1])
  end

  defp reports_to_options(_, _), do: [{"— No manager —", ""}]

  defp normalize_adapter(nil), do: "claude_code"
  defp normalize_adapter(""), do: "claude_code"
  defp normalize_adapter("anthropic"), do: "claude_code"
  defp normalize_adapter("claude"), do: "claude_code"
  defp normalize_adapter(value), do: value

  # ── View helpers ──────────────────────────────────────────────────────

  def role_options do
    Agent.role_options()
    |> Enum.map(fn role -> {role_label(role), to_string(role)} end)
  end

  def adapter_options do
    Agents.adapter_options()
    |> Enum.map(fn adapter -> {adapter_label_human(adapter), to_string(adapter)} end)
  end

  def render_markdown(text), do: Markdown.to_html(text)

  def health_status_label(:healthy), do: "Healthy"
  def health_status_label(:degraded), do: "Degraded"
  def health_status_label(:unhealthy), do: "Unhealthy"
  def health_status_label(:unavailable), do: "Unavailable"
  def health_status_label(:unknown), do: "Unknown"
  def health_status_label(_), do: "Unknown"

  def status_label(:idle), do: "idle"
  def status_label(:running), do: "running"
  def status_label(:error), do: "error"
  def status_label(:sleeping), do: "sleeping"
  def status_label(:offline), do: "offline"
  def status_label(:paused), do: "paused"
  def status_label(other), do: other |> to_string()

  def role_label(:engineer), do: "Engineer"
  def role_label(:ceo), do: "CEO"
  def role_label(:cto), do: "CTO"
  def role_label(:product_manager), do: "Product Manager"
  def role_label(:designer), do: "Designer"
  def role_label(role), do: role |> to_string() |> String.replace("_", " ") |> String.capitalize()

  def wake_reason_label("issue_commented"), do: "Comment received"
  def wake_reason_label("issue_comment_mentioned"), do: "Mentioned in comment"
  def wake_reason_label("issue_blockers_resolved"), do: "Blockers resolved"
  def wake_reason_label("issue_children_completed"), do: "Children completed"
  def wake_reason_label(_), do: "Unknown"

  def format_relative(nil), do: "—"

  def format_relative(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      diff < 604_800 -> "#{div(diff, 86_400)}d ago"
      true -> Calendar.strftime(dt, "%b %d")
    end
  end

  def format_relative(_), do: "—"

  def issue_status_label(status) when is_atom(status) do
    status |> to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  def issue_status_label(_), do: "—"

  def issue_status_class(:done), do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"
  def issue_status_class(:in_progress), do: "border-amber-500/25 bg-amber-500/10 text-amber-300"
  def issue_status_class(:in_review), do: "border-violet-500/25 bg-violet-500/10 text-violet-300"
  def issue_status_class(:blocked), do: "border-red-500/25 bg-red-500/10 text-red-300"
  def issue_status_class(:cancelled), do: "border-border bg-surface text-text-quaternary"
  def issue_status_class(_), do: "border-border bg-surface text-text-secondary"

  def run_status_class("succeeded"),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"

  def run_status_class("completed"),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"

  def run_status_class("failed"), do: "border-red-500/25 bg-red-500/10 text-red-300"
  def run_status_class("cancelled"), do: "border-border bg-surface text-text-quaternary"
  def run_status_class("running"), do: "border-brand/30 bg-brand/10 text-brand"
  def run_status_class("pending"), do: "border-border bg-surface text-text-secondary"
  def run_status_class("queued"), do: "border-border bg-surface text-text-secondary"
  def run_status_class(_), do: "border-border bg-surface text-text-secondary"

  def run_dot_class("succeeded"), do: "bg-emerald-400"
  def run_dot_class("completed"), do: "bg-emerald-400"
  def run_dot_class("failed"), do: "bg-red-400"
  def run_dot_class("cancelled"), do: "bg-gray-500"
  def run_dot_class("running"), do: "bg-brand"
  def run_dot_class("pending"), do: "bg-amber-300"
  def run_dot_class("queued"), do: "bg-amber-300"
  def run_dot_class(_), do: "bg-gray-400"

  @sensitive_substrings ~w(TOKEN SECRET PASSWORD API_KEY AUTH)

  def mask_secret_like(key, value) when is_binary(key) and is_binary(value) do
    upper = String.upcase(key)

    if Enum.any?(@sensitive_substrings, &String.contains?(upper, &1)) do
      mask(value)
    else
      value
    end
  end

  def mask_secret_like(_key, value), do: to_string(value)

  defp mask(value) when is_binary(value) do
    case String.length(value) do
      n when n <= 4 -> "••••"
      _ -> String.slice(value, 0, 4) <> "••••" <> String.slice(value, -4, 4)
    end
  end

  def agent_initials(agent) do
    agent.name
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map(&String.first/1)
    |> Enum.join()
    |> String.upcase()
  end

  def health_pill_class(:healthy), do: "border-success/25 bg-success/10 text-success"
  def health_pill_class(:degraded), do: "border-amber-500/25 bg-amber-500/10 text-amber-300"
  def health_pill_class(:unhealthy), do: "border-red-500/25 bg-red-500/10 text-red-300"
  def health_pill_class(:unavailable), do: "border-border bg-surface text-text-quaternary"
  def health_pill_class(_), do: "border-border bg-surface text-text-secondary"

  def adapter_label(nil), do: "No adapter"
  def adapter_label(""), do: "No adapter"
  def adapter_label(adapter), do: adapter_label_human(adapter)

  defp adapter_label_human(:claude_code), do: "Claude Code"
  defp adapter_label_human(:codex), do: "Codex"
  defp adapter_label_human(:cursor), do: "Cursor"
  defp adapter_label_human(:http), do: "HTTP"
  defp adapter_label_human(:openclaw), do: "OpenClaw"
  defp adapter_label_human(:process), do: "Process"
  defp adapter_label_human(other), do: to_string(other)

  def reports_count(%{children: children}) when is_list(children), do: length(children)
  def reports_count(_), do: 0

  def is_paused?(%Agent{status: :paused}), do: true
  def is_paused?(%Agent{governance_status: "paused"}), do: true
  def is_paused?(_), do: false

  attr :label, :string, required: true
  attr :help, :string, default: nil
  attr :name, :string, required: true
  attr :checked, :boolean, default: false

  def permission_row(assigns) do
    ~H"""
    <label class="flex cursor-pointer items-start justify-between gap-4 px-5 py-4 hover:bg-surface-hover/40">
      <div class="min-w-0 flex-1">
        <p class="text-sm font-510 text-text-primary">{@label}</p>
        <p :if={@help} class="mt-0.5 text-xs text-text-quaternary">{@help}</p>
      </div>
      <div class="relative pt-0.5">
        <input type="hidden" name={@name} value="false" />
        <input type="checkbox" name={@name} value="true" checked={@checked} class="peer sr-only" />
        <span class="block h-5 w-9 rounded-full border border-border bg-surface peer-checked:border-brand peer-checked:bg-brand transition-colors">
        </span>
        <span class="absolute left-0.5 top-1 h-3.5 w-3.5 rounded-full bg-text-quaternary peer-checked:left-[18px] peer-checked:bg-white transition-all">
        </span>
      </div>
    </label>
    """
  end
end
