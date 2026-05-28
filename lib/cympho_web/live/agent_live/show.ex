defmodule CymphoWeb.AgentLive.Show do
  use CymphoWeb, :live_view

  alias Cympho.Agents
  alias Cympho.Agents.Agent
  alias Cympho.Agents.InstructionFiles
  alias Cympho.Agents.RuntimeEnv
  alias Cympho.Adapters.Error, as: AdapterError
  alias Cympho.Adapters.Registry, as: AdapterRegistry
  alias Cympho.Adapters.RuntimeOptions
  alias Cympho.AgentInstructionStudio
  alias Cympho.HeartbeatEngine
  alias Cympho.Issues
  alias Cympho.RuntimeCapacity
  alias Cympho.RuntimeProfiles
  alias Cympho.Secrets
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

    case get_scoped_agent(socket, id) do
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
      case get_scoped_agent(socket, id) do
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
    selected_profile_id = selected_profile_from_params(agent_params, socket.assigns.agent)

    selected_adapter =
      selected_adapter_from_params(agent_params, socket.assigns.agent, selected_profile_id)

    runtime = runtime_form_from_params(agent_params, socket.assigns.agent, selected_profile_id)

    full_params =
      agent_params
      |> Map.put("adapter", selected_adapter)
      |> Map.put(
        "config",
        build_adapter_config(socket.assigns.agent, selected_adapter, runtime, selected_profile_id)
      )
      |> Map.put(
        "runtime_config",
        build_runtime_config(socket.assigns.agent, env_rows, selected_profile_id)
      )
      |> Map.put("permissions", permissions)

    changeset =
      socket.assigns.agent
      |> Agents.change_agent(normalize_agent_params(full_params))
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:env_rows, env_rows)
     |> assign(:env_vars, env_map_from_rows(env_rows))
     |> assign(:permissions, permissions)
     |> assign(:selected_adapter, selected_adapter)
     |> assign_runtime_profile(selected_profile_id)
     |> assign_runtime_form(runtime)
     |> assign(:adapter_health_check_result, nil)
     |> assign(:instruction_patch_feedback, nil)
     |> assign(:form, to_form(changeset))}
  end

  def handle_event("config_save", %{"agent" => agent_params} = params, socket) do
    env_rows = env_rows_from_params(params, socket.assigns.env_rows)
    permissions = permissions_from_params(params, socket.assigns.permissions)
    selected_profile_id = selected_profile_from_params(agent_params, socket.assigns.agent)

    selected_adapter =
      selected_adapter_from_params(agent_params, socket.assigns.agent, selected_profile_id)

    runtime = runtime_form_from_params(agent_params, socket.assigns.agent, selected_profile_id)

    full_params =
      agent_params
      |> Map.put("adapter", selected_adapter)
      |> Map.put(
        "config",
        build_adapter_config(socket.assigns.agent, selected_adapter, runtime, selected_profile_id)
      )
      |> Map.put(
        "runtime_config",
        build_runtime_config(socket.assigns.agent, env_rows, selected_profile_id)
      )
      |> Map.put("permissions", permissions)

    case Agents.update_agent(socket.assigns.agent, normalize_agent_params(full_params)) do
      {:ok, agent} ->
        {socket, revision_message} =
          maybe_record_config_revision(socket, socket.assigns.agent, agent)

        {:noreply,
         socket
         |> put_flash(:info, revision_message)
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
         |> assign(:env_vars, env_map_from_rows(env_rows))
         |> assign(:permissions, permissions)
         |> assign(:selected_adapter, selected_adapter)
         |> assign_runtime_profile(selected_profile_id)
         |> assign_runtime_form(runtime)
         |> assign(:adapter_health_check_result, nil)
         |> assign(:instruction_patch_feedback, nil)
         |> assign(:form, to_form(Map.put(changeset, :action, :update)))}
    end
  end

  def handle_event("apply_instruction_patch", %{"patch" => patch_id}, socket) do
    role = current_form_value(socket, :role, socket.assigns.agent.role)

    instructions =
      current_form_value(socket, :instructions, socket.assigns.agent.instructions || "")

    selected_adapter =
      socket.assigns[:selected_adapter] || selected_adapter_from_agent(socket.assigns.agent)

    runtime = runtime_form_from_assigns(socket.assigns)
    studio = instruction_studio(role, instructions, selected_adapter, runtime)

    case Enum.find(studio.patches, &(&1.id == patch_id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "Instruction patch not found.")}

      patch ->
        updated_instructions = append_instruction_patch(instructions, patch)
        updated_studio = instruction_studio(role, updated_instructions, selected_adapter, runtime)

        params =
          socket
          |> current_agent_form_params(%{"instructions" => updated_instructions})
          |> normalize_agent_params()

        changeset =
          socket.assigns.agent
          |> Agents.change_agent(params)
          |> Map.put(:action, :validate)

        feedback = %{
          patch_id: patch.id,
          title: patch.title,
          before_score: studio.score,
          after_score: updated_studio.score,
          changed?: updated_instructions != to_string(instructions || "")
        }

        {:noreply,
         socket
         |> assign(:instruction_patch_feedback, feedback)
         |> assign(:form, to_form(changeset))}
    end
  end

  def handle_event("restore_config_revision", %{"id" => revision_id}, socket) do
    case Agents.restore_config_revision(socket.assigns.agent.id, revision_id,
           created_by_user_id: current_user_id(socket)
         ) do
      {:ok, agent} ->
        {:noreply,
         socket
         |> put_flash(:info, "Instruction revision restored.")
         |> assign_agent(agent)}

      {:error, :pending_board_approval, approval_id} ->
        {:noreply,
         put_flash(
           socket,
           :info,
           "Restore requires board approval. Request submitted (##{String.slice(approval_id, 0, 8)})."
         )}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Instruction revision not found.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not restore instruction revision.")}
    end
  end

  def handle_event("add_env_row", _params, socket) do
    rows = socket.assigns.env_rows ++ [%{key: "", value: ""}]

    {:noreply,
     socket
     |> assign(:env_rows, rows)
     |> assign(:env_vars, env_map_from_rows(rows))
     |> assign(:adapter_health_check_result, nil)}
  end

  def handle_event("remove_env_row", %{"index" => index}, socket) do
    idx = String.to_integer(index)
    rows = List.delete_at(socket.assigns.env_rows, idx)
    rows = if rows == [], do: [%{key: "", value: ""}], else: rows

    {:noreply,
     socket
     |> assign(:env_rows, rows)
     |> assign(:env_vars, env_map_from_rows(rows))
     |> assign(:adapter_health_check_result, nil)}
  end

  def handle_event("toggle_permission", %{"key" => key}, socket) do
    current = !!Map.get(socket.assigns.permissions, key, false)
    permissions = Map.put(socket.assigns.permissions, key, !current)
    {:noreply, assign(socket, :permissions, permissions)}
  end

  def handle_event("select_runtime_profile", %{"profile_id" => profile_id}, socket) do
    profile_id = RuntimeProfiles.normalize_id(profile_id)

    selected_adapter =
      RuntimeProfiles.adapter_for(
        profile_id,
        socket.assigns[:selected_adapter] || selected_adapter_from_agent(socket.assigns.agent)
      )

    runtime =
      if RuntimeProfiles.custom?(profile_id) do
        runtime_form_from_assigns(socket.assigns)
      else
        runtime_form_fallback(socket.assigns.agent, selected_adapter, profile_id)
      end

    {:noreply,
     socket
     |> assign(:selected_adapter, selected_adapter)
     |> assign_runtime_profile(profile_id)
     |> assign_runtime_form(runtime)
     |> assign(:adapter_health_check_result, nil)}
  end

  def handle_event("apply_runtime_preset", %{"preset" => preset_id}, socket) do
    case RuntimeProfiles.quick_preset(preset_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Unknown runtime preset.")}

      preset ->
        profile_id = RuntimeProfiles.normalize_id(preset.profile_id)

        selected_adapter =
          RuntimeProfiles.adapter_for(
            profile_id,
            socket.assigns[:selected_adapter] || selected_adapter_from_agent(socket.assigns.agent)
          )
          |> normalize_adapter()

        runtime = runtime_form_fallback(socket.assigns.agent, selected_adapter, profile_id)

        changeset =
          socket.assigns.agent
          |> Agents.change_agent(%{
            "adapter" => selected_adapter,
            "max_concurrent_jobs" => preset.max_concurrent_jobs
          })
          |> Map.put(:action, :validate)

        {:noreply,
         socket
         |> put_flash(:info, "#{preset.name} preset applied. Save to persist it.")
         |> assign(:selected_adapter, selected_adapter)
         |> assign_runtime_profile(profile_id)
         |> assign_runtime_form(runtime)
         |> assign(:adapter_health_check_result, nil)
         |> assign(:form, to_form(changeset))}
    end
  end

  def handle_event("test_adapter", _params, socket) do
    selected_adapter =
      socket.assigns[:selected_adapter] || selected_adapter_from_agent(socket.assigns.agent)

    runtime = runtime_form_from_assigns(socket.assigns)
    profile_id = socket.assigns[:selected_runtime_profile_id] || RuntimeProfiles.custom_id()

    config =
      socket.assigns.agent
      |> build_adapter_config(selected_adapter, runtime, profile_id)
      |> preflight_config(
        selected_adapter,
        socket.assigns[:env_vars] || %{},
        socket.assigns[:secret_count] || 0
      )

    {:noreply,
     assign(socket, :adapter_health_check_result, adapter_health_check(selected_adapter, config))}
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
            {:ok, agent} = get_scoped_agent(socket, agent.id)

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
        {:ok, agent} = get_scoped_agent(socket, socket.assigns.agent.id)

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
        {:ok, agent} = get_scoped_agent(socket, socket.assigns.agent.id)

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

  defp get_scoped_agent(socket, id) do
    case socket.assigns[:current_company] do
      %{id: company_id} -> Agents.get_company_agent(company_id, id)
      _ -> {:error, :not_found}
    end
  end

  defp assign_agent(socket, agent) do
    agent = Cympho.Repo.preload(agent, [:parent, :children])
    wake_history = Wakes.list_agent_wakes(agent.id)
    runs = HeartbeatEngine.list_runs_for_agent(agent.id, limit: 30)
    recent_issues = Issues.list_recent_for_agent(agent.id, 10)
    env_vars = RuntimeEnv.from_agent(agent)
    secret_count = Secrets.list_secrets_for_agent(agent.id) |> length()
    changeset = Agents.change_agent(agent)
    selected_profile_id = RuntimeProfiles.from_agent(agent)
    config_revisions = Agents.list_config_revisions(agent.id, limit: 8)
    latest_prompt_tuning_revision = latest_prompt_tuning_revision(config_revisions)

    socket
    |> assign(:agent, agent)
    |> assign(:wake_history, wake_history)
    |> assign(:recent_runs, runs)
    |> assign(:latest_run, List.first(runs))
    |> assign(:recent_issues, recent_issues)
    |> assign(:env_vars, env_vars)
    |> assign(:secret_count, secret_count)
    |> assign(:env_rows, env_rows_from(agent))
    |> assign(:selected_adapter, selected_adapter_from_agent(agent))
    |> assign_runtime_profile(selected_profile_id)
    |> assign_runtime_form(runtime_form_from_agent(agent))
    |> assign(:adapter_health_check_result, nil)
    |> assign(:instruction_patch_feedback, nil)
    |> assign(:config_revisions, config_revisions)
    |> assign(:latest_config_revision, List.first(config_revisions))
    |> assign(:latest_prompt_tuning_revision, latest_prompt_tuning_revision)
    |> assign(:permissions, normalise_permissions(agent.permissions))
    |> assign(:instructions_preview?, false)
    |> assign(:form, to_form(changeset))
    |> assign(:reports_to_options, reports_to_options(socket.assigns[:current_company], agent.id))
    |> refresh_skills()
    |> maybe_default_tab()
  end

  defp refresh_skills(socket) do
    company_id = socket.assigns[:current_company] && socket.assigns.current_company.id
    plugins = if company_id, do: Skills.list_plugins(company_id: company_id), else: []
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
    |> Map.drop([
      "model",
      "provider",
      "runtime_command",
      "process_preset",
      "process_args",
      "runtime_cwd",
      "openclaw_endpoint",
      "openclaw_runtime",
      "openclaw_harness_id",
      "runtime_profile_id"
    ])
    |> normalize_parent_id()
  end

  defp normalize_parent_id(params) do
    case Map.get(params, "parent_id") do
      "" -> Map.put(params, "parent_id", nil)
      _ -> params
    end
  end

  defp current_agent_form_params(socket, overrides) do
    agent = socket.assigns.agent

    %{
      "name" => current_form_value(socket, :name, agent.name),
      "title" => current_form_value(socket, :title, agent.title),
      "role" => current_form_value(socket, :role, agent.role),
      "parent_id" => current_form_value(socket, :parent_id, agent.parent_id),
      "adapter" => socket.assigns[:selected_adapter] || selected_adapter_from_agent(agent),
      "max_concurrent_jobs" =>
        current_form_value(socket, :max_concurrent_jobs, agent.max_concurrent_jobs),
      "instructions" => current_form_value(socket, :instructions, agent.instructions || "")
    }
    |> Map.merge(overrides)
  end

  defp current_form_value(socket, field, fallback) do
    case socket.assigns.form[field].value do
      nil -> fallback
      value -> value
    end
  end

  defp append_instruction_patch(current, patch) do
    current = current |> to_string() |> String.trim()
    marker = "## #{patch.title}"
    block = "#{marker}\n#{patch.body}"

    cond do
      String.contains?(current, marker) or String.contains?(current, patch.body) ->
        current

      current == "" ->
        block

      true ->
        current <> "\n\n" <> block
    end
  end

  defp maybe_record_config_revision(socket, before_agent, after_agent) do
    if tracked_config_changed?(before_agent, after_agent) do
      case Agents.create_config_revision(after_agent, %{
             created_by_user_id: current_user_id(socket)
           }) do
        {:ok, revision} ->
          {socket, "Configuration saved. Instruction revision v#{revision.version} recorded."}

        {:error, _changeset} ->
          {socket, "Configuration saved, but instruction revision history could not be recorded."}
      end
    else
      {socket, "Configuration saved."}
    end
  end

  defp tracked_config_changed?(before_agent, after_agent) do
    Enum.any?([:role, :adapter, :instructions, :config, :runtime_config], fn field ->
      Map.get(before_agent, field) != Map.get(after_agent, field)
    end)
  end

  defp current_user_id(socket) do
    case socket.assigns[:current_user] do
      %{id: id} -> id
      _ -> nil
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

  defp build_runtime_config(%Agent{runtime_config: existing}, rows, profile_id) do
    profile_runtime_config = RuntimeProfiles.runtime_config(profile_id)
    profile_env = Map.get(profile_runtime_config, "env", %{})

    env =
      rows
      |> Enum.reject(fn %{key: k} -> String.trim(k) == "" end)
      |> Enum.reduce(%{}, fn %{key: k, value: v}, acc -> Map.put(acc, String.trim(k), v) end)

    (existing || %{})
    |> Map.merge(profile_runtime_config)
    |> Map.put("env", Map.merge(profile_env, env))
    |> Map.put("profile_id", RuntimeProfiles.normalize_id(profile_id))
  end

  defp env_map_from_rows(rows) do
    rows
    |> List.wrap()
    |> Enum.reject(fn %{key: key} -> String.trim(to_string(key || "")) == "" end)
    |> Enum.reduce(%{}, fn %{key: key, value: value}, acc ->
      Map.put(acc, String.trim(to_string(key)), to_string(value || ""))
    end)
  end

  defp build_adapter_config(agent, adapter, runtime, profile_id) do
    agent
    |> adapter_config_base(profile_id)
    |> do_build_adapter_config(adapter, runtime)
  end

  defp adapter_config_base(%Agent{config: existing}, profile_id) do
    if RuntimeProfiles.custom?(profile_id) do
      existing || %{}
    else
      RuntimeProfiles.config(profile_id)
    end
  end

  defp do_build_adapter_config(config, "codex", runtime) do
    config
    |> Map.put("provider", "openai-codex")
    |> put_clean("model", runtime.model)
  end

  defp do_build_adapter_config(config, "claude_code", runtime) do
    config
    |> put_clean("command", runtime.command)
  end

  defp do_build_adapter_config(config, "cursor", runtime) do
    config
    |> put_clean("command", runtime.command)
    |> put_clean("model", runtime.model)
  end

  defp do_build_adapter_config(config, "openclaw", runtime) do
    config
    |> put_clean("provider", runtime.provider)
    |> put_clean("model", runtime.model)
    |> put_clean("endpoint", runtime.openclaw_endpoint)
    |> put_clean("agent_runtime", runtime.openclaw_runtime)
    |> put_clean("harness_id", runtime.openclaw_harness_id)
  end

  defp do_build_adapter_config(config, "process", runtime) do
    preset_defaults = RuntimeOptions.process_defaults(runtime.process_preset)

    config
    |> Map.merge(preset_defaults)
    |> put_clean("process_preset", runtime.process_preset)
    |> put_clean("provider", runtime.provider)
    |> put_clean("model", runtime.model)
    |> put_clean("command", runtime.command)
    |> put_clean("args", args_from_text(runtime.process_args))
    |> put_clean("cwd", runtime.cwd)
  end

  defp do_build_adapter_config(config, _adapter, _runtime), do: config

  defp preflight_config(config, adapter, env_vars, secret_count) do
    config
    |> put_preflight_api_key(adapter, env_vars, secret_count)
  end

  defp put_preflight_api_key(config, "codex", env_vars, secret_count) do
    config
    |> put_preflight_key("api_key", env_first(env_vars, ["OPENAI_API_KEY", "CODEX_API_KEY"]))
    |> maybe_mark_secret_key("api_key", secret_count)
  end

  defp put_preflight_api_key(config, "claude_code", env_vars, secret_count) do
    config
    |> put_preflight_key("api_key", env_first(env_vars, ["ANTHROPIC_API_KEY"]))
    |> maybe_mark_secret_key("api_key", secret_count)
  end

  defp put_preflight_api_key(config, "openclaw", env_vars, secret_count) do
    config
    |> put_preflight_key("api_key", env_first(env_vars, ["OPENCLAW_API_KEY"]))
    |> maybe_mark_secret_key("api_key", secret_count)
  end

  defp put_preflight_api_key(config, "agrenting", env_vars, secret_count) do
    config
    |> put_preflight_key("api_key", env_first(env_vars, ["AGRENTING_API_KEY"]))
    |> put_preflight_key("base_url", env_first(env_vars, ["AGRENTING_URL"]))
    |> maybe_mark_secret_key("api_key", secret_count)
  end

  defp put_preflight_api_key(config, _adapter, _env_vars, _secret_count), do: config

  defp put_preflight_key(config, _key, value) when value in [nil, ""], do: config
  defp put_preflight_key(config, key, value), do: Map.put(config, key, value)

  defp maybe_mark_secret_key(config, key, secret_count) when secret_count > 0 do
    Map.put_new(config, key, "__encrypted_secret_available__")
  end

  defp maybe_mark_secret_key(config, _key, _secret_count), do: config

  defp env_first(env_vars, keys) do
    Enum.find_value(keys, fn key ->
      value = Map.get(env_vars || %{}, key)
      if value in [nil, ""], do: nil, else: value
    end)
  end

  defp put_clean(map, _key, value) when value in [nil, ""], do: map
  defp put_clean(map, key, value), do: Map.put(map, key, value)

  defp selected_adapter_from_params(params, agent, profile_id) do
    fallback =
      params
      |> Map.get("adapter")
      |> case do
        nil -> selected_adapter_from_agent(agent)
        adapter -> normalize_adapter(adapter)
      end

    profile_id
    |> RuntimeProfiles.adapter_for(fallback)
    |> normalize_adapter()
  end

  defp selected_profile_from_params(params, agent) do
    params
    |> Map.get("runtime_profile_id")
    |> case do
      nil -> RuntimeProfiles.from_agent(agent)
      profile_id -> RuntimeProfiles.normalize_id(profile_id)
    end
  end

  defp selected_adapter_from_agent(%Agent{adapter: nil}), do: "claude_code"

  defp selected_adapter_from_agent(%Agent{adapter: adapter}),
    do: adapter |> to_string() |> normalize_adapter()

  defp assign_runtime_form(socket, runtime) do
    socket
    |> assign(:runtime_model, runtime.model)
    |> assign(:runtime_provider, runtime.provider)
    |> assign(:runtime_command, runtime.command)
    |> assign(:process_preset, runtime.process_preset)
    |> assign(:process_args, runtime.process_args)
    |> assign(:runtime_cwd, runtime.cwd)
    |> assign(:openclaw_endpoint, runtime.openclaw_endpoint)
    |> assign(:openclaw_runtime, runtime.openclaw_runtime)
    |> assign(:openclaw_harness_id, runtime.openclaw_harness_id)
  end

  defp assign_runtime_profile(socket, profile_id) do
    profile_id = RuntimeProfiles.normalize_id(profile_id)

    socket
    |> assign(:runtime_profiles, RuntimeProfiles.all())
    |> assign(:selected_runtime_profile_id, profile_id)
    |> assign(:runtime_profile, RuntimeProfiles.get!(profile_id))
  end

  defp runtime_form_from_params(params, %Agent{} = agent, profile_id) do
    selected_adapter = selected_adapter_from_params(params, agent, profile_id)
    fallback = runtime_form_fallback(agent, selected_adapter, profile_id)

    if RuntimeProfiles.custom?(profile_id) do
      provider =
        params
        |> param_string("provider", fallback.provider)
        |> default_runtime_provider(selected_adapter)

      process_preset = param_string(params, "process_preset", fallback.process_preset)

      %{
        model: param_string(params, "model", fallback.model),
        provider: provider,
        command: param_string(params, "runtime_command", fallback.command),
        process_preset: process_preset,
        process_args: param_string(params, "process_args", fallback.process_args),
        cwd: param_string(params, "runtime_cwd", fallback.cwd),
        openclaw_endpoint: param_string(params, "openclaw_endpoint", fallback.openclaw_endpoint),
        openclaw_runtime: param_string(params, "openclaw_runtime", fallback.openclaw_runtime),
        openclaw_harness_id:
          param_string(params, "openclaw_harness_id", fallback.openclaw_harness_id)
      }
      |> maybe_default_runtime_model(selected_adapter, provider, process_preset)
    else
      fallback
    end
  end

  defp runtime_form_fallback(agent, selected_adapter, profile_id) do
    if RuntimeProfiles.custom?(profile_id) do
      runtime_form_from_agent(agent)
    else
      RuntimeProfiles.config(profile_id)
      |> runtime_form_from_config(selected_adapter)
    end
  end

  defp runtime_form_from_assigns(assigns) do
    %{
      model: assigns[:runtime_model] || "",
      provider: assigns[:runtime_provider] || "",
      command: assigns[:runtime_command] || "",
      process_preset: assigns[:process_preset] || RuntimeOptions.process_default_preset(),
      process_args: assigns[:process_args] || "",
      cwd: assigns[:runtime_cwd] || "",
      openclaw_endpoint: assigns[:openclaw_endpoint] || "",
      openclaw_runtime: assigns[:openclaw_runtime] || "subagent",
      openclaw_harness_id: assigns[:openclaw_harness_id] || ""
    }
  end

  defp runtime_form_from_agent(%Agent{config: config, adapter: adapter}) do
    config = config || %{}
    adapter = adapter |> to_string() |> normalize_adapter()
    runtime_form_from_config(config, adapter)
  end

  defp runtime_form_from_config(config, adapter) do
    config = config || %{}
    provider = config["provider"] || default_provider(adapter)
    process_preset = config["process_preset"] || RuntimeOptions.process_default_preset()

    %{
      model: config["model"] || default_model(adapter, provider),
      provider: provider,
      command: config["command"] || default_command(adapter, process_preset),
      process_preset: process_preset,
      process_args: args_to_text(config["args"]),
      cwd: config["cwd"] || "",
      openclaw_endpoint: config["endpoint"] || "",
      openclaw_runtime: config["agent_runtime"] || "subagent",
      openclaw_harness_id: config["harness_id"] || ""
    }
  end

  defp maybe_default_runtime_model(runtime, adapter, provider, process_preset) do
    valid_models =
      adapter
      |> runtime_model_options(provider, process_preset)
      |> Enum.map(fn {_label, value} -> value end)

    if runtime.model in [nil, ""] or
         (valid_models != [] and runtime.model not in valid_models) do
      %{runtime | model: default_model(adapter, provider, process_preset)}
    else
      runtime
    end
  end

  defp runtime_model_options("codex", _provider, _preset),
    do: Cympho.Adapters.CodexAdapter.model_options()

  defp runtime_model_options("cursor", _provider, _preset),
    do: RuntimeOptions.cursor_model_options()

  defp runtime_model_options("openclaw", provider, _preset),
    do: RuntimeOptions.openclaw_model_options(provider)

  defp runtime_model_options("process", provider, _preset),
    do: RuntimeOptions.process_model_options(provider)

  defp runtime_model_options(_adapter, _provider, _preset), do: []

  defp default_provider("openclaw"), do: RuntimeOptions.openclaw_default_provider()
  defp default_provider("process"), do: ""
  defp default_provider("codex"), do: "openai-codex"
  defp default_provider(_), do: ""

  defp default_runtime_provider(provider, "openclaw") when provider in [nil, ""],
    do: RuntimeOptions.openclaw_default_provider()

  defp default_runtime_provider(provider, _adapter), do: provider || ""

  defp default_model("codex", _provider), do: Cympho.Adapters.CodexAdapter.default_model()
  defp default_model("cursor", _provider), do: RuntimeOptions.cursor_default_model()
  defp default_model("openclaw", provider), do: RuntimeOptions.openclaw_default_model(provider)
  defp default_model("process", provider), do: default_model("process", provider, nil)
  defp default_model(_, _provider), do: ""

  defp default_model("process", provider, _preset) do
    provider
    |> RuntimeOptions.process_model_options()
    |> List.first()
    |> case do
      {_label, value} -> value
      nil -> ""
    end
  end

  defp default_model(adapter, provider, _preset), do: default_model(adapter, provider)

  defp default_command("cursor", _preset), do: "agent"

  defp default_command("process", preset),
    do: RuntimeOptions.process_defaults(preset)["command"] || ""

  defp default_command(_, _preset), do: ""

  defp param_string(params, key, fallback) do
    case Map.get(params, key) do
      value when is_binary(value) -> String.trim(value)
      _ -> fallback || ""
    end
  end

  defp args_from_text(nil), do: []
  defp args_from_text(""), do: []

  defp args_from_text(text) when is_binary(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp args_to_text(args) when is_list(args), do: Enum.join(args, "\n")
  defp args_to_text(_), do: ""

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

  def runtime_profile_options, do: RuntimeProfiles.options()

  def codex_model_options, do: Cympho.Adapters.CodexAdapter.model_options()
  def cursor_model_options, do: RuntimeOptions.cursor_model_options()
  def openclaw_provider_options, do: RuntimeOptions.openclaw_provider_options()
  def openclaw_provider_model_options, do: RuntimeOptions.openclaw_provider_model_options()
  def openclaw_model_options(provider), do: RuntimeOptions.openclaw_model_options(provider)
  def process_preset_options, do: RuntimeOptions.process_preset_options()
  def process_provider_options, do: RuntimeOptions.process_provider_options()
  def process_provider_model_options, do: RuntimeOptions.process_provider_model_options()
  def process_model_options(provider), do: RuntimeOptions.process_model_options(provider)
  def runtime_profile_summary(profile), do: RuntimeProfiles.summary_value(profile)
  def quick_runtime_presets, do: RuntimeProfiles.quick_presets()

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
  def role_label(:release_engineer), do: "Release Engineer"
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

  defp adapter_error_for_run(run), do: AdapterError.from_run(run)

  defp adapter_health_check(adapter, config) do
    adapter = normalize_adapter(adapter)

    case AdapterRegistry.lookup(String.to_existing_atom(adapter)) do
      {:ok, module} ->
        result = module.health_check(config || %{})
        health_check_result(adapter, result)

      :error ->
        health_check_result(adapter, %{
          status: :unhealthy,
          message: "Adapter is not registered",
          checked_at: DateTime.utc_now()
        })
    end
  rescue
    ArgumentError ->
      health_check_result(adapter, %{
        status: :unhealthy,
        message: "Adapter is not registered",
        checked_at: DateTime.utc_now()
      })

    error ->
      health_check_result(adapter, %{
        status: :unhealthy,
        message: Exception.message(error),
        checked_at: DateTime.utc_now()
      })
  end

  defp health_check_result(adapter, result) when is_map(result) do
    status = normalize_health_check_status(result[:status] || result["status"])
    message = result[:message] || result["message"] || "Health check completed."

    error =
      if status == :healthy, do: nil, else: AdapterError.normalize(message, adapter: adapter)

    %{
      status: status,
      label: health_check_status_label(status),
      adapter: adapter_label_human(adapter),
      message: message,
      checked_at: result[:checked_at] || result["checked_at"] || DateTime.utc_now(),
      error: error
    }
  end

  defp normalize_health_check_status(:healthy), do: :healthy
  defp normalize_health_check_status(:degraded), do: :degraded
  defp normalize_health_check_status(:unhealthy), do: :unavailable
  defp normalize_health_check_status(:unavailable), do: :unavailable
  defp normalize_health_check_status("healthy"), do: :healthy
  defp normalize_health_check_status("degraded"), do: :degraded
  defp normalize_health_check_status("unhealthy"), do: :unavailable
  defp normalize_health_check_status("unavailable"), do: :unavailable
  defp normalize_health_check_status(_), do: :unavailable

  defp health_check_status_label(:healthy), do: "Passed"
  defp health_check_status_label(:degraded), do: "Needs attention"
  defp health_check_status_label(:unavailable), do: "Blocked"
  defp health_check_status_label(_), do: "Unknown"

  defp health_check_badge_class(:healthy),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"

  defp health_check_badge_class(:degraded),
    do: "border-amber-500/25 bg-amber-500/10 text-amber-300"

  defp health_check_badge_class(:unavailable),
    do: "border-red-500/25 bg-red-500/10 text-red-300"

  defp health_check_badge_class(_), do: "border-border bg-surface text-text-tertiary"

  defp adapter_error_category_label(:missing_binary), do: "Missing command"
  defp adapter_error_category_label(:missing_credentials), do: "Missing credentials"
  defp adapter_error_category_label(:auth_failed), do: "Auth failed"
  defp adapter_error_category_label(:timeout), do: "Timeout"
  defp adapter_error_category_label(:malformed_output), do: "Malformed output"
  defp adapter_error_category_label(:no_output), do: "No output"
  defp adapter_error_category_label(:nonzero_exit), do: "Non-zero exit"
  defp adapter_error_category_label(_), do: "Unclassified"

  defp adapter_error_badge_class(:missing_binary),
    do: "border-amber-500/30 bg-amber-500/10 text-amber-200"

  defp adapter_error_badge_class(:missing_credentials),
    do: "border-amber-500/30 bg-amber-500/10 text-amber-200"

  defp adapter_error_badge_class(:auth_failed),
    do: "border-red-500/30 bg-red-500/10 text-red-200"

  defp adapter_error_badge_class(:timeout),
    do: "border-yellow-500/30 bg-yellow-500/10 text-yellow-200"

  defp adapter_error_badge_class(:malformed_output),
    do: "border-violet-500/30 bg-violet-500/10 text-violet-200"

  defp adapter_error_badge_class(:no_output),
    do: "border-border bg-surface text-text-tertiary"

  defp adapter_error_badge_class(:nonzero_exit),
    do: "border-red-500/30 bg-red-500/10 text-red-200"

  defp adapter_error_badge_class(_), do: "border-border bg-surface text-text-tertiary"

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

  defp runtime_capacity(adapter, max_jobs, runs) do
    running_runs =
      runs
      |> List.wrap()
      |> Enum.count(&(&1.status in ["running", "queued", "pending"]))

    RuntimeCapacity.agent(%{adapter: adapter, max_concurrent_jobs: max_jobs}, running_runs)
  end

  defp capacity_badge_class(:safe), do: "border-green-500/25 bg-green-500/10 text-green-400"
  defp capacity_badge_class(:watch), do: "border-yellow-500/25 bg-yellow-500/10 text-yellow-300"
  defp capacity_badge_class(:high), do: "border-red-500/25 bg-red-500/10 text-red-300"
  defp capacity_badge_class(_), do: "border-border bg-surface text-text-tertiary"

  defp capacity_dot_class(:safe), do: "bg-green-400"
  defp capacity_dot_class(:watch), do: "bg-yellow-300"
  defp capacity_dot_class(:high), do: "bg-red-400"
  defp capacity_dot_class(_), do: "bg-text-quaternary"

  def adapter_label(nil), do: "No adapter"
  def adapter_label(""), do: "No adapter"
  def adapter_label(adapter), do: adapter_label_human(adapter)

  def adapter_runtime_label(%Agent{adapter: :claude_code} = agent) do
    runtime_config_value(agent, "command") ||
      Application.get_env(:cympho, :claude_code_command) ||
      System.get_env("CYMPHO_CLAUDE_COMMAND") ||
      "claude"
  end

  def adapter_runtime_label(%Agent{adapter: "claude_code"} = agent),
    do: adapter_runtime_label(%Agent{agent | adapter: :claude_code})

  def adapter_runtime_label(_agent), do: nil

  def runtime_command_label(command, agent) when command in [nil, ""],
    do: adapter_runtime_label(agent)

  def runtime_command_label(command, _agent), do: command

  defp adapter_readiness(adapter, runtime) do
    adapter = normalize_adapter(adapter)
    autonomy_enabled? = Cympho.Orchestrator.Dispatcher.enabled?()

    items =
      [selected_adapter_item(adapter)] ++
        readiness_items(adapter, runtime) ++
        [execution_mode_item(autonomy_enabled?)]

    blocked_count = Enum.count(items, &(&1.status == :blocked))
    attention_count = Enum.count(items, &(&1.status == :attention))

    status =
      cond do
        blocked_count > 0 -> :command_not_found
        attention_count > 0 -> :missing_config
        not autonomy_enabled? -> :review_mode
        true -> :ready
      end

    %{
      label: readiness_label(status, attention_count),
      status: status,
      summary: adapter_readiness_summary(adapter, status, attention_count),
      items: items
    }
  end

  defp readiness_label(:ready, _count), do: "Ready"
  defp readiness_label(:review_mode, _count), do: "Review mode only"
  defp readiness_label(:command_not_found, _count), do: "Command not found"
  defp readiness_label(:missing_config, 1), do: "Missing config"
  defp readiness_label(:missing_config, count), do: "#{count} config checks"
  defp readiness_label(_status, _count), do: "Needs attention"

  defp adapter_readiness_summary(adapter, :ready, _count) do
    "#{adapter_label_human(adapter)} has the basic runtime fields it needs."
  end

  defp adapter_readiness_summary(adapter, :review_mode, _count) do
    "#{adapter_label_human(adapter)} is configured, but autonomous dispatch is disabled for review mode."
  end

  defp adapter_readiness_summary(adapter, :command_not_found, _count) do
    "#{adapter_label_human(adapter)} points at a CLI command Cympho cannot find on this machine."
  end

  defp adapter_readiness_summary(adapter, _status, count) do
    "#{adapter_label_human(adapter)} needs #{count} runtime check#{if count == 1, do: "", else: "s"} before autonomous runs."
  end

  defp selected_adapter_item(adapter) do
    readiness_item(:ok, "Selected adapter", adapter_label_human(adapter))
  end

  defp execution_mode_item(true) do
    readiness_item(:ok, "Execution mode", "Autonomous dispatch is enabled.")
  end

  defp execution_mode_item(false) do
    readiness_item(
      :info,
      "Execution mode",
      "Review mode only. Saving is safe, but agents will not auto-dispatch.",
      target_path: "/operations#runtime-services",
      target_label: "Open service gates"
    )
  end

  defp readiness_items("claude_code", runtime) do
    command = first_present([runtime.command, adapter_runtime_label(runtime.agent), "claude"])

    [
      command_item("Runtime command", command,
        shell?: true,
        target_id: "agent-runtime-profile",
        target_label: "Change profile"
      ),
      claude_credentials_item(command, runtime),
      readiness_item(
        :ok,
        "Model routing",
        "Set ANTHROPIC_MODEL, ANTHROPIC_BASE_URL, or wrapper defaults when using custom providers."
      )
    ]
  end

  defp readiness_items("codex", runtime) do
    [
      command_item("CLI command", "codex",
        target_id: "agent-runtime-profile",
        target_label: "Change profile"
      ),
      model_item("Codex model", runtime.model,
        target_id: "agent-codex-model",
        target_label: "Choose model"
      ),
      credentials_item(runtime, ["OPENAI_API_KEY", "CODEX_API_KEY"], "OpenAI/Codex key",
        target_id: "agent-env-vars",
        target_label: "Add env var"
      ),
      readiness_item(:ok, "Invocation", "Runs as codex --model #{runtime.model}.")
    ]
  end

  defp readiness_items("cursor", runtime) do
    [
      command_item("Cursor command", runtime.command || "agent",
        target_id: "agent-cursor-command",
        target_label: "Edit command"
      ),
      model_item("Cursor model", runtime.model,
        target_id: "agent-cursor-model",
        target_label: "Choose model"
      ),
      readiness_item(
        :ok,
        "Account",
        "Uses the local Cursor CLI account and installed model access."
      )
    ]
  end

  defp readiness_items("openclaw", runtime) do
    [
      readiness_item(:ok, "Provider", runtime.provider || "default provider"),
      model_item("Provider model", runtime.model,
        target_id: "agent-openclaw-model",
        target_label: "Choose model"
      ),
      if(runtime.endpoint in [nil, ""],
        do:
          readiness_item(
            :attention,
            "Gateway endpoint",
            "Add the OpenClaw gateway URL before autonomous runs.",
            target_id: "agent-openclaw-endpoint",
            target_label: "Set endpoint"
          ),
        else: readiness_item(:ok, "Gateway endpoint", runtime.endpoint)
      )
    ]
  end

  defp readiness_items("process", runtime) do
    [
      command_item("Command", runtime.command,
        target_id: "agent-process-command",
        target_label: "Edit command"
      ),
      model_item("Forwarded model", runtime.model,
        target_id: "agent-process-model",
        target_label: "Choose model"
      ),
      readiness_item(
        :ok,
        "Preset",
        "Preset #{runtime.process_preset || "custom"} controls args and model forwarding."
      )
    ]
  end

  defp readiness_items("agrenting", runtime) do
    config = runtime.agent.config || %{}

    [
      credentials_item(runtime, ["AGRENTING_API_KEY"], "Agrenting API key",
        target_path: "/companies/#{runtime.agent.company_id}/secrets",
        target_label: "Open secrets"
      ),
      required_config_item(config, "agent_did", "Remote agent DID"),
      required_config_item(config, "capability", "Default capability"),
      required_config_item(config, "max_price", "Max price per run"),
      readiness_item(:ok, "Delivery mode", config["delivery_mode"] || "output")
    ]
  end

  defp readiness_items(_adapter, _runtime) do
    [
      readiness_item(
        :attention,
        "Adapter contract",
        "This adapter does not yet expose runtime readiness checks.",
        target_id: "agent-runtime-profile",
        target_label: "Change profile"
      )
    ]
  end

  defp claude_credentials_item(command, runtime) do
    cond do
      credentials_present?(runtime, ["ANTHROPIC_API_KEY"]) ->
        readiness_item(:ok, "Credentials", "Anthropic-compatible credentials are configured.")

      command not in [nil, "", "claude"] ->
        readiness_item(
          :ok,
          "Credentials",
          "#{command} can source provider credentials from a wrapper or $HOME/.cld."
        )

      true ->
        readiness_item(
          :attention,
          "Credentials",
          "Add ANTHROPIC_API_KEY as a secret/env var or choose a wrapper command.",
          target_id: "agent-env-vars",
          target_label: "Add env var"
        )
    end
  end

  defp credentials_item(runtime, keys, label, opts) do
    if credentials_present?(runtime, keys) do
      readiness_item(:ok, label, "Credential source is configured through secrets or env.")
    else
      key_hint = Enum.join(keys, " or ")

      readiness_item(
        :attention,
        label,
        "Add #{key_hint} as a secret or runtime env var.",
        opts
      )
    end
  end

  defp credentials_present?(runtime, keys) do
    runtime.secret_count > 0 ||
      Enum.any?(keys, fn key -> Map.get(runtime.env_vars || %{}, key) not in [nil, ""] end)
  end

  defp command_item(label, command, opts) when command in [nil, ""] do
    readiness_item(:attention, label, "Choose the command Cympho should execute.", opts)
  end

  defp command_item(label, command, opts) do
    if command_available?(command, opts) do
      readiness_item(:ok, label, "#{command} was found on this machine.")
    else
      readiness_item(
        :blocked,
        label,
        "#{command} was not found in PATH or configured shell env.",
        opts
      )
    end
  end

  defp model_item(label, model, opts) when model in [nil, ""] do
    readiness_item(:attention, label, "Choose a model before autonomous runs.", opts)
  end

  defp model_item(label, model, _opts), do: readiness_item(:ok, label, model)

  defp required_config_item(config, key, label) do
    case Map.get(config, key) do
      value when value not in [nil, ""] -> readiness_item(:ok, label, to_string(value))
      _ -> readiness_item(:attention, label, "Set by the remote-agent hire flow.")
    end
  end

  defp readiness_item(status, label, detail, opts \\ []) do
    target =
      opts
      |> Keyword.take([:target_id, :target_label, :target_path])
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Map.new()

    Map.merge(%{status: status, label: label, detail: detail}, target)
  end

  defp command_available?(command, opts) do
    System.find_executable(command) != nil or
      (Keyword.get(opts, :shell?, false) and shell_command_available?(command))
  end

  defp shell_command_available?(command) do
    command = shell_quote(command)
    script = "source \"$HOME/.cld\" 2>/dev/null || true; command -v #{command} >/dev/null 2>&1"

    case System.cmd("bash", ["-lc", script], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp shell_quote(value) do
    "'" <> String.replace(to_string(value), "'", "'\"'\"'") <> "'"
  end

  defp first_present(values) do
    Enum.find(values, fn
      value when value in [nil, ""] -> false
      _ -> true
    end)
  end

  defp readiness_badge_class(:ready) do
    "rounded-full border border-emerald-500/25 bg-emerald-500/10 px-2.5 py-1 text-xs font-510 text-emerald-300"
  end

  defp readiness_badge_class(:missing_config) do
    "rounded-full border border-amber-500/25 bg-amber-500/10 px-2.5 py-1 text-xs font-510 text-amber-300"
  end

  defp readiness_badge_class(:review_mode) do
    "rounded-full border border-sky-500/25 bg-sky-500/10 px-2.5 py-1 text-xs font-510 text-sky-300"
  end

  defp readiness_badge_class(:command_not_found) do
    "rounded-full border border-red-500/25 bg-red-500/10 px-2.5 py-1 text-xs font-510 text-red-300"
  end

  defp readiness_dot_class(:ok), do: "h-2 w-2 rounded-full bg-emerald-400"
  defp readiness_dot_class(:info), do: "h-2 w-2 rounded-full bg-sky-400"
  defp readiness_dot_class(:attention), do: "h-2 w-2 rounded-full bg-amber-400"
  defp readiness_dot_class(:blocked), do: "h-2 w-2 rounded-full bg-red-400"

  defp instruction_studio(role, instructions, adapter, runtime) do
    AgentInstructionStudio.analyze(role, instructions,
      adapter: adapter,
      command: runtime.command,
      model: runtime.model,
      provider: runtime.provider
    )
  end

  defp studio_badge_class(:good) do
    "rounded-full border border-emerald-500/25 bg-emerald-500/10 px-2.5 py-1 text-xs font-510 text-emerald-300"
  end

  defp studio_badge_class(:weak) do
    "rounded-full border border-amber-500/25 bg-amber-500/10 px-2.5 py-1 text-xs font-510 text-amber-300"
  end

  defp studio_badge_class(:attention) do
    "rounded-full border border-red-500/25 bg-red-500/10 px-2.5 py-1 text-xs font-510 text-red-300"
  end

  defp studio_badge_class(_status) do
    "rounded-full border border-border bg-surface px-2.5 py-1 text-xs font-510 text-text-tertiary"
  end

  defp eval_coverage_badge_class(:ok) do
    "rounded-full border border-emerald-500/25 bg-emerald-500/10 px-2.5 py-1 text-xs font-510 text-emerald-300"
  end

  defp eval_coverage_badge_class(:attention) do
    "rounded-full border border-amber-500/25 bg-amber-500/10 px-2.5 py-1 text-xs font-510 text-amber-300"
  end

  defp eval_coverage_badge_class(_status) do
    "rounded-full border border-border bg-surface px-2.5 py-1 text-xs font-510 text-text-tertiary"
  end

  defp eval_result_class(:ok), do: "border-border bg-canvas/60"
  defp eval_result_class(:attention), do: "border-amber-500/25 bg-amber-500/[0.06]"
  defp eval_result_class(_status), do: "border-border bg-canvas/60"

  defp eval_expectation_class(:pass) do
    "rounded bg-emerald-500/10 px-1.5 py-0.5 text-[10px] text-emerald-300"
  end

  defp eval_expectation_class(:catch) do
    "rounded bg-amber-500/10 px-1.5 py-0.5 text-[10px] text-amber-300"
  end

  defp eval_expectation_class(_expectation) do
    "rounded bg-canvas px-1.5 py-0.5 text-[10px] text-text-tertiary"
  end

  defp eval_result_status_text(result) do
    if Map.get(result, :passed?), do: "passed", else: "failed"
  end

  defp studio_status_dot_class(:ok), do: "h-2 w-2 rounded-full bg-emerald-400"
  defp studio_status_dot_class(:good), do: "h-2 w-2 rounded-full bg-emerald-400"
  defp studio_status_dot_class(:weak), do: "h-2 w-2 rounded-full bg-amber-400"
  defp studio_status_dot_class(:attention), do: "h-2 w-2 rounded-full bg-red-400"
  defp studio_status_dot_class(_status), do: "h-2 w-2 rounded-full bg-text-quaternary"

  defp studio_card_class(:attention), do: "border-red-500/25 bg-red-500/[0.06]"
  defp studio_card_class(:weak), do: "border-amber-500/25 bg-amber-500/[0.06]"
  defp studio_card_class(_status), do: "border-border bg-surface"

  defp instruction_patch_class(:primary), do: "border-brand/30 bg-brand/10"
  defp instruction_patch_class(:danger), do: "border-red-500/25 bg-red-500/[0.06]"
  defp instruction_patch_class(_tone), do: "border-border bg-surface"

  defp instruction_save_guardrails(studio, latest_revision) do
    []
    |> maybe_score_drop_guardrail(studio, latest_revision)
    |> maybe_contract_drop_guardrail(studio, latest_revision)
    |> maybe_conflict_guardrail(studio)
    |> Enum.reverse()
  end

  defp maybe_score_drop_guardrail(guardrails, studio, %{studio_score: previous_score})
       when is_integer(previous_score) and studio.score < previous_score do
    [
      %{
        status: :attention,
        title: "Studio score drops on save",
        detail:
          "Current edit scores #{studio.score}/100, down from saved revision #{previous_score}/100."
      }
      | guardrails
    ]
  end

  defp maybe_score_drop_guardrail(guardrails, _studio, _latest_revision), do: guardrails

  defp maybe_contract_drop_guardrail(guardrails, studio, latest_revision) do
    current = studio_audit_status(studio, :custom_override_coverage)
    previous = revision_audit_status(latest_revision, "custom_override_coverage")

    if previous == "ok" and current in [:weak, :attention] do
      [
        %{
          status: :weak,
          title: "Final-comment contract weakened",
          detail:
            "This edit removes explicit references to the required delivery/review/owner update fields."
        }
        | guardrails
      ]
    else
      guardrails
    end
  end

  defp maybe_conflict_guardrail(guardrails, studio) do
    if studio_audit_status(studio, :guardrail_conflicts) == :attention do
      [
        %{
          status: :attention,
          title: "Conflicting guardrail found",
          detail:
            "Custom instructions appear to contradict comments, verification, review, or governance."
        }
        | guardrails
      ]
    else
      guardrails
    end
  end

  defp studio_audit_status(studio, key) do
    studio.audits
    |> Enum.find(&(&1.key == key))
    |> case do
      nil -> nil
      audit -> audit.status
    end
  end

  defp revision_audit_status(nil, _key), do: nil

  defp revision_audit_status(revision, key) do
    revision.studio_audits
    |> Map.get("audits", [])
    |> Enum.find(&(Map.get(&1, "key") == key))
    |> case do
      nil -> nil
      audit -> Map.get(audit, "status")
    end
  end

  defp instruction_guardrail_class(:attention), do: "border-red-500/25 bg-red-500/[0.06]"
  defp instruction_guardrail_class(:weak), do: "border-amber-500/25 bg-amber-500/[0.06]"
  defp instruction_guardrail_class(_status), do: "border-border bg-surface"

  defp revision_score(nil), do: "No score"
  defp revision_score(%{studio_score: nil}), do: "No score"
  defp revision_score(%{studio_score: score}), do: "#{score}/100"

  defp revision_score_delta(_revision, nil), do: "baseline"
  defp revision_score_delta(%{studio_score: nil}, _previous), do: "no score"
  defp revision_score_delta(_revision, %{studio_score: nil}), do: "baseline"

  defp revision_score_delta(%{studio_score: score}, %{studio_score: previous_score}) do
    delta = score - previous_score

    cond do
      delta > 0 -> "+#{delta}"
      delta < 0 -> "#{delta}"
      true -> "no change"
    end
  end

  defp revision_source_label("restore"), do: "Restored"
  defp revision_source_label("prompt_tuning"), do: "Prompt tuning"
  defp revision_source_label("manual"), do: "Saved"
  defp revision_source_label(nil), do: "Saved"
  defp revision_source_label(source), do: String.capitalize(to_string(source))

  defp latest_prompt_tuning_revision(config_revisions) do
    Enum.find(config_revisions, &(&1.source == "prompt_tuning"))
  end

  defp revision_status_badge(nil), do: studio_badge_class(nil)

  defp revision_status_badge(status) when is_binary(status) do
    status
    |> String.to_existing_atom()
    |> studio_badge_class()
  rescue
    ArgumentError -> studio_badge_class(nil)
  end

  defp runtime_config_value(%Agent{runtime_config: runtime_config, config: config}, key) do
    Map.get(runtime_config || %{}, key) ||
      Map.get(runtime_config || %{}, existing_atom_key(key)) ||
      Map.get(config || %{}, key) ||
      Map.get(config || %{}, existing_atom_key(key))
  end

  defp existing_atom_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp existing_atom_key(key), do: key

  defp adapter_label_human("claude_code"), do: "Claude Code"
  defp adapter_label_human("codex"), do: "Codex"
  defp adapter_label_human("cursor"), do: "Cursor"
  defp adapter_label_human("http"), do: "HTTP"
  defp adapter_label_human("openclaw"), do: "OpenClaw"
  defp adapter_label_human("process"), do: "Process"
  defp adapter_label_human("agrenting"), do: "Agrenting"
  defp adapter_label_human(:claude_code), do: "Claude Code"
  defp adapter_label_human(:codex), do: "Codex"
  defp adapter_label_human(:cursor), do: "Cursor"
  defp adapter_label_human(:http), do: "HTTP"
  defp adapter_label_human(:openclaw), do: "OpenClaw"
  defp adapter_label_human(:process), do: "Process"
  defp adapter_label_human(:agrenting), do: "Agrenting"
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
