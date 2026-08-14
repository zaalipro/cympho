defmodule CymphoWeb.AgentLive.New do
  use CymphoWeb, :live_view
  require Logger

  alias Cympho.AgentHeartbeat
  alias Cympho.Agents
  alias Cympho.Agents.Agent
  alias Cympho.Agents.RolePlaybook
  alias Cympho.Agents.RuntimeEnv
  alias Cympho.Adapters.RuntimeOptions
  alias Cympho.Comments
  alias Cympho.Issues.AutoAssignment
  alias Cympho.OrgHealth
  alias Cympho.Orchestrator.Dispatcher
  alias Cympho.RuntimeProfiles
  alias Cympho.Secrets
  alias CymphoWeb.UserAuth

  @default_role "engineer"
  @repo_delivery_roles Agent.pr_delivery_roles()

  @default_attrs %{
    "role" => @default_role,
    "adapter" => "claude_code",
    "max_concurrent_jobs" => "3",
    "instructions" => RolePlaybook.default_overrides_template(:engineer)
  }

  @impl true
  def mount(params, _session, socket) do
    company = socket.assigns[:current_company]
    role = prefill_role(params)
    selected_profile_id = selected_profile_from_params(params)
    attrs = initial_attrs(params, company, selected_profile_id)
    selected_adapter = selected_adapter_from_params(attrs, selected_profile_id)

    runtime =
      attrs
      |> runtime_form_from_params(selected_adapter, selected_profile_id)
      |> maybe_overlay_company_openai_chat(company, selected_adapter)

    changeset = Agents.change_agent(%Agent{}, attrs)

    env_text = env_text_from_profile(selected_profile_id)
    profile = RuntimeProfiles.get!(selected_profile_id)

    {:ok,
     socket
     |> assign(:page_title, "New Agent")
     |> assign(:pending_approval_id, nil)
     |> assign(:env_text, env_text)
     |> assign(:hire_context, hire_context(params, company, role))
     |> assign(:hire_form_path, hire_form_path(params))
     |> assign(:return_to, return_to(params))
     |> assign(:selected_adapter, selected_adapter)
     |> assign_runtime_profile(selected_profile_id)
     |> assign_runtime_form(runtime)
     |> assign(:reports_to_options, reports_to_options(company, nil))
     |> assign(:form, to_form(changeset))
     |> assign_hire_readiness(company, selected_adapter, profile, env_text, runtime)}
  end

  @impl true
  def handle_event("validate", %{"agent" => agent_params}, socket) do
    company = socket.assigns[:current_company]

    agent_params = maybe_refresh_instructions_for_role(agent_params)
    selected_profile_id = selected_profile_from_params(agent_params)
    env_text = env_text_from_params(agent_params, selected_profile_id)
    agent_params = Map.put(agent_params, "env_text", env_text)
    selected_adapter = selected_adapter_from_params(agent_params, selected_profile_id)

    runtime =
      agent_params
      |> runtime_form_from_params(selected_adapter, selected_profile_id)
      |> maybe_overlay_company_openai_chat(company, selected_adapter)

    profile = RuntimeProfiles.get!(selected_profile_id)

    changeset =
      %Agent{}
      |> Agents.change_agent(
        agent_params
        |> maybe_apply_runtime_profile(selected_profile_id)
        |> maybe_put_adapter_config(selected_adapter, runtime, selected_profile_id)
        |> maybe_put_runtime_profile(selected_profile_id)
        |> maybe_put_profile_concurrency(agent_params, selected_profile_id)
        |> normalize_agent_params()
        |> maybe_put_company_id(company)
      )
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:env_text, env_text)
     |> assign(:selected_adapter, selected_adapter)
     |> assign_runtime_profile(selected_profile_id)
     |> assign_runtime_form(runtime)
     |> assign(:form, to_form(changeset))
     |> assign_hire_readiness(company, selected_adapter, profile, env_text, runtime)}
  end

  def handle_event("save", %{"agent" => agent_params}, socket) do
    company = socket.assigns[:current_company]
    selected_profile_id = selected_profile_from_params(agent_params)
    env_text = env_text_from_params(agent_params, selected_profile_id)
    agent_params = Map.put(agent_params, "env_text", env_text)
    selected_adapter = selected_adapter_from_params(agent_params, selected_profile_id)

    runtime =
      agent_params
      |> runtime_form_from_params(selected_adapter, selected_profile_id)
      |> maybe_overlay_company_openai_chat(company, selected_adapter)

    profile = RuntimeProfiles.get!(selected_profile_id)

    readiness =
      hire_readiness(
        company,
        selected_adapter,
        profile,
        env_text,
        runtime,
        socket.assigns[:hire_form_path]
      )

    if readiness.status == :needs_key do
      {:noreply,
       socket
       |> assign(:env_text, env_text)
       |> assign(:selected_adapter, selected_adapter)
       |> assign_runtime_profile(selected_profile_id)
       |> assign_runtime_form(runtime)
       |> assign(:hire_readiness, readiness)
       |> put_flash(
         :error,
         "Add #{readiness.primary_key} before hiring — this agent cannot run without a provider key."
       )}
    else
      params =
        agent_params
        |> maybe_apply_runtime_profile(selected_profile_id)
        |> maybe_put_adapter_config(selected_adapter, runtime, selected_profile_id)
        |> maybe_put_runtime_profile(selected_profile_id)
        |> maybe_put_profile_concurrency(agent_params, selected_profile_id)
        |> normalize_agent_params()
        |> maybe_put_company_id(company)

      case Agents.create_agent(params) do
        {:ok, agent} ->
          socket = maybe_assign_waiting_role_work(socket, agent)
          {:noreply, push_navigate(socket, to: socket.assigns.return_to || ~p"/agents")}

        {:error, :pending_board_approval, approval_id} ->
          socket =
            socket
            |> put_flash(
              :info,
              "Agent hire requires board approval. " <>
                "A request has been submitted and is pending review."
            )
            |> assign(:pending_approval_id, approval_id)

          {:noreply, socket}

        {:error, changeset} ->
          {:noreply,
           socket
           |> assign(:selected_adapter, selected_adapter)
           |> assign_runtime_profile(selected_profile_id)
           |> assign_runtime_form(runtime)
           |> assign(:hire_readiness, readiness)
           |> assign(form: to_form(Map.put(changeset, :action, :insert)))}
      end
    end
  end

  def role_options do
    Agent.role_options()
    |> Enum.map(fn role -> {role_label(role), to_string(role)} end)
  end

  def adapter_options do
    Agents.adapter_options()
    |> Enum.map(fn adapter -> {adapter_label(adapter), to_string(adapter)} end)
  end

  def codex_model_options(current_model \\ nil) do
    options = Cympho.Adapters.CodexAdapter.model_options()
    current_model = current_model |> to_string() |> String.trim()

    if current_model != "" and
         Enum.all?(options, fn {_label, value} -> value != current_model end) do
      options ++ [{"#{current_model} (custom)", current_model}]
    else
      options
    end
  end

  def cursor_model_options, do: RuntimeOptions.cursor_model_options()
  def openclaw_provider_options, do: RuntimeOptions.openclaw_provider_options()
  def openclaw_provider_model_options, do: RuntimeOptions.openclaw_provider_model_options()
  def openclaw_model_options(provider), do: RuntimeOptions.openclaw_model_options(provider)
  def process_preset_options, do: RuntimeOptions.process_preset_options()
  def process_provider_options, do: RuntimeOptions.process_provider_options()
  def process_provider_model_options, do: RuntimeOptions.process_provider_model_options()
  def process_model_options(provider), do: RuntimeOptions.process_model_options(provider)
  def runtime_profile_options, do: RuntimeProfiles.options()
  def runtime_profile_summary(profile), do: RuntimeProfiles.summary_value(profile)

  def runtime_profile_concurrency(profile),
    do: RuntimeProfiles.max_concurrent_jobs_for_profile(profile.id)

  def runtime_profile_capability(profile) do
    if profile.id == RuntimeProfiles.custom_id() do
      nil
    else
      runtime_profile_capability_badge(profile)
    end
  end

  defp runtime_profile_capability_badge(profile) do
    runtime = %{
      adapter: profile.adapter,
      config: profile.config || %{},
      runtime_config: profile.runtime_config || %{}
    }

    cond do
      Cympho.AgentRuntimeCapabilities.repo_delivery_capable?(runtime) ->
        %{label: "Repo capable", class: "border-success/25 bg-success/10 text-success"}

      profile.adapter == "openai_chat" ->
        %{label: "Text/action only", class: "border-amber-500/25 bg-amber-500/10 text-amber-200"}

      true ->
        nil
    end
  end

  defp maybe_put_company_id(params, %{id: company_id}) do
    Map.put(params, "company_id", company_id)
  end

  defp maybe_put_company_id(params, _), do: params

  defp initial_attrs(params, company, profile_id) do
    role = prefill_role(params)

    @default_attrs
    |> Map.put("role", to_string(role))
    |> Map.put("adapter", default_adapter(company))
    |> Map.put("instructions", RolePlaybook.default_overrides_template(role))
    |> maybe_put_prefill_name(params, role)
    |> maybe_put_prefill_parent(params, company)
    |> maybe_apply_runtime_profile(profile_id)
    |> maybe_put_runtime_profile(profile_id)
    |> maybe_put_profile_concurrency(params, profile_id)
    |> maybe_put_company_id(company)
  end

  defp prefill_role(%{"role" => role}) do
    Agent.normalize_role(role) || Agent.normalize_role(@default_role)
  end

  defp prefill_role(_params), do: Agent.normalize_role(@default_role)

  defp maybe_put_prefill_name(attrs, params, role) do
    case clean_prefill_string(Map.get(params, "name")) do
      nil ->
        if Map.has_key?(params, "role"),
          do: Map.put(attrs, "name", Agent.role_label(role)),
          else: attrs

      name ->
        Map.put(attrs, "name", name)
    end
  end

  defp maybe_put_prefill_parent(attrs, params, company) do
    parent_id = clean_prefill_string(Map.get(params, "parent_id"))

    if valid_parent_id?(company, parent_id),
      do: Map.put(attrs, "parent_id", parent_id),
      else: attrs
  end

  defp valid_parent_id?(_company, nil), do: false

  defp valid_parent_id?(%{id: company_id}, parent_id) do
    company_id
    |> Agents.list_agents_by_company()
    |> Enum.any?(&(&1.id == parent_id))
  end

  defp valid_parent_id?(_company, _parent_id), do: false

  defp clean_prefill_string(value) when is_binary(value) do
    value = value |> String.trim() |> String.slice(0, 120)
    if value == "", do: nil, else: value
  end

  defp clean_prefill_string(_value), do: nil

  defp hire_context(%{"role" => _role}, %{id: company_id}, role) when is_atom(role) do
    company_id
    |> OrgHealth.snapshot()
    |> Map.get(:role_demand_gaps, [])
    |> Enum.find(&(&1.role == role))
    |> case do
      nil ->
        nil

      gap ->
        %{
          label: gap.label,
          role: role,
          open_issues: gap.open_issues,
          examples: gap.examples,
          suggested_parent: gap.suggested_parent
        }
    end
  end

  defp hire_context(_params, _company, _role), do: nil

  defp return_to(%{"return_to" => return_to}), do: UserAuth.safe_return_path(return_to)
  defp return_to(_params), do: nil

  defp maybe_assign_waiting_role_work(socket, %Agent{company_id: company_id, role: role} = agent) do
    case socket.assigns[:hire_context] do
      %{role: ^role} when is_binary(company_id) ->
        case AutoAssignment.assign_waiting_role_work_with_issues(company_id, role) do
          {:ok, assigned_issues, queued} ->
            ensure_agent_heartbeat(agent)
            add_staffing_hire_receipts(assigned_issues, agent)
            wake_count = enqueue_staffing_hire_wakes(assigned_issues, agent)

            put_flash(
              socket,
              :info,
              demand_hire_flash(agent, length(assigned_issues), queued, wake_count)
            )

          _ ->
            socket
        end

      _ ->
        socket
    end
  end

  defp add_staffing_hire_receipts(assigned_issues, %Agent{} = agent) do
    Enum.each(assigned_issues, fn issue ->
      _ = system_comment(issue, staffing_hire_receipt(issue, agent))
    end)
  end

  defp staffing_hire_receipt(issue, %Agent{} = agent) do
    role = Agent.normalize_role(issue.assigned_role) || agent.role
    role_label = Agent.role_label(role)
    name = agent.name || agent.id

    "[handoff] Demand-backed hire assigned this #{role_label} issue to #{name}. " <>
      "Why: queued #{String.downcase(role_label)} work had #{staffing_gap_reason(role)}. " <>
      "Current state: assigned and queued for manual dispatch. " <>
      "Next decision: #{name} should produce delivery evidence, hand off to the right role, or block with a recoverable reason. " <>
      "Restart packet: read the issue brief, acceptance criteria, latest comments, and this staffing receipt before acting."
  end

  defp staffing_gap_reason(role) when role in @repo_delivery_roles,
    do: "no eligible repo-capable owner"

  defp staffing_gap_reason(_role), do: "no eligible owner"

  defp system_comment(issue, body) do
    Comments.create_comment(%{
      body: body,
      author_type: "system",
      author_id: "00000000-0000-0000-0000-000000000000",
      issue_id: issue.id
    })
  end

  defp ensure_agent_heartbeat(%Agent{id: agent_id, name: name}) do
    case AgentHeartbeat.start_for_agent(agent_id) do
      {:ok, _pid} ->
        :ok

      {:error, :already_started} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[AgentLive.New] demand-backed hire #{name || agent_id} created but heartbeat did not start: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp enqueue_staffing_hire_wakes(assigned_issues, %Agent{id: agent_id, role: role}) do
    assigned_issues
    |> Enum.count(fn issue ->
      case Dispatcher.enqueue_wake(issue.id, "manual_dispatch", %{
             "source" => "demand_backed_hire",
             "agent_id" => agent_id,
             "role" => to_string(role)
           }) do
        {:ok, _} -> true
        _ -> false
      end
    end)
  end

  defp demand_hire_flash(%Agent{name: name}, assigned, _queued, wake_count) when assigned > 0 do
    "#{name} created, assigned to #{assigned} waiting #{plural_noun(assigned, "issue")}, and queued #{wake_count} #{plural_noun(wake_count, "wake")}."
  end

  defp demand_hire_flash(%Agent{name: name}, _assigned, queued, _wake_count) when queued > 0 do
    "#{name} created. #{queued} waiting #{plural_noun(queued, "issue")} still need eligible capacity."
  end

  defp demand_hire_flash(%Agent{name: name}, _assigned, _queued, _wake_count) do
    "#{name} created. No matching waiting issues needed assignment."
  end

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
      "openai_chat_endpoint",
      "openclaw_endpoint",
      "openclaw_runtime",
      "openclaw_harness_id"
    ])
    |> normalize_parent_id()
    |> normalize_runtime_env()
  end

  defp selected_adapter_from_params(params, profile_id) do
    fallback =
      params
      |> Map.get("adapter", "claude_code")
      |> normalize_adapter()

    profile_id
    |> RuntimeProfiles.adapter_for(fallback)
    |> normalize_adapter()
  end

  defp maybe_apply_runtime_profile(params, profile_id) do
    if RuntimeProfiles.custom?(profile_id) do
      params
    else
      profile = RuntimeProfiles.get!(profile_id)

      params
      |> Map.put("adapter", profile.adapter)
      |> Map.put("config", profile.config || %{})
    end
  end

  defp maybe_put_runtime_profile(params, profile_id) do
    runtime_config =
      profile_id
      |> RuntimeProfiles.runtime_config()
      |> Map.put("profile_id", RuntimeProfiles.normalize_id(profile_id))

    Map.put(params, "runtime_config", runtime_config)
  end

  defp maybe_put_profile_concurrency(attrs, source_params, profile_id) do
    cond do
      explicit_concurrency?(source_params) ->
        attrs

      max_jobs = RuntimeProfiles.max_concurrent_jobs_for_profile(profile_id) ->
        Map.put(attrs, "max_concurrent_jobs", to_string(max_jobs))

      true ->
        attrs
    end
  end

  defp explicit_concurrency?(params) do
    case Map.get(params, "max_concurrent_jobs") do
      value when is_binary(value) -> String.trim(value) != ""
      value when is_integer(value) -> true
      _ -> false
    end
  end

  defp maybe_put_adapter_config(params, adapter, runtime, profile_id) do
    config =
      params
      |> Map.get("config", %{})
      |> adapter_config_base(profile_id)
      |> build_adapter_config(adapter, runtime)

    Map.put(params, "config", config)
  end

  defp adapter_config_base(config, profile_id) do
    if RuntimeProfiles.custom?(profile_id) do
      config || %{}
    else
      RuntimeProfiles.config(profile_id)
    end
  end

  defp build_adapter_config(config, "codex", runtime) do
    config
    |> Map.put("provider", "openai-codex")
    |> put_clean("model", runtime.model)
  end

  defp build_adapter_config(config, "cursor", runtime) do
    config
    |> put_clean("command", runtime.command)
    |> put_clean("model", runtime.model)
  end

  defp build_adapter_config(config, "openclaw", runtime) do
    config
    |> put_clean("provider", runtime.provider)
    |> put_clean("model", runtime.model)
    |> put_clean("endpoint", runtime.openclaw_endpoint)
    |> put_clean("agent_runtime", runtime.openclaw_runtime)
    |> put_clean("harness_id", runtime.openclaw_harness_id)
  end

  defp build_adapter_config(config, "openai_chat", runtime) do
    config
    |> put_clean("model", runtime.model)
    |> put_clean("endpoint", runtime.openai_chat_endpoint)
  end

  defp build_adapter_config(config, "process", runtime) do
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

  defp build_adapter_config(config, _adapter, _runtime), do: config

  defp put_clean(map, _key, value) when value in [nil, "", []], do: map
  defp put_clean(map, key, value), do: Map.put(map, key, value)

  defp assign_runtime_form(socket, runtime) do
    socket
    |> assign(:runtime_model, runtime.model)
    |> assign(:runtime_provider, runtime.provider)
    |> assign(:runtime_command, runtime.command)
    |> assign(:process_preset, runtime.process_preset)
    |> assign(:process_args, runtime.process_args)
    |> assign(:runtime_cwd, runtime.cwd)
    |> assign(:openai_chat_endpoint, runtime.openai_chat_endpoint)
    |> assign(:openclaw_endpoint, runtime.openclaw_endpoint)
    |> assign(:openclaw_runtime, runtime.openclaw_runtime)
    |> assign(:openclaw_harness_id, runtime.openclaw_harness_id)
  end

  defp runtime_form_from_params(params, adapter, profile_id) do
    fallback = runtime_form_fallback(adapter, profile_id)

    if RuntimeProfiles.custom?(profile_id) do
      runtime_form_from_custom_params(params, adapter, fallback)
    else
      fallback
    end
  end

  defp runtime_form_from_custom_params(params, adapter, fallback) do
    process_preset = param_string(params, "process_preset", fallback.process_preset)
    preset_defaults = RuntimeOptions.process_defaults(process_preset)

    provider =
      params
      |> param_string("provider", fallback.provider)
      |> default_process_value(adapter, fallback.provider, preset_defaults["provider"])
      |> default_runtime_provider(adapter)

    command =
      params
      |> param_string("runtime_command", fallback.command)
      |> default_process_value(adapter, fallback.command, preset_defaults["command"])

    %{
      model: param_string(params, "model", fallback.model),
      provider: provider,
      command: command,
      process_preset: process_preset,
      process_args: param_string(params, "process_args", fallback.process_args),
      cwd: param_string(params, "runtime_cwd", fallback.cwd),
      openai_chat_endpoint:
        param_string(params, "openai_chat_endpoint", fallback.openai_chat_endpoint),
      openclaw_endpoint: param_string(params, "openclaw_endpoint", fallback.openclaw_endpoint),
      openclaw_runtime: param_string(params, "openclaw_runtime", fallback.openclaw_runtime),
      openclaw_harness_id:
        param_string(params, "openclaw_harness_id", fallback.openclaw_harness_id)
    }
    |> maybe_default_runtime_model(adapter, provider, process_preset)
  end

  defp runtime_form_fallback(adapter, profile_id) do
    if RuntimeProfiles.custom?(profile_id) do
      default_runtime_form(adapter)
    else
      profile_id
      |> RuntimeProfiles.config()
      |> runtime_form_from_config(adapter)
    end
  end

  defp runtime_form_from_config(config, adapter) do
    config = config || %{}
    provider = config["provider"] || default_provider(adapter)
    process_preset = config["process_preset"] || RuntimeOptions.process_default_preset()

    %{
      model: config["model"] || default_model(adapter, provider, process_preset),
      provider: provider,
      command: config["command"] || default_command(adapter, process_preset),
      process_preset: process_preset,
      process_args: args_to_text(config["args"]),
      cwd: config["cwd"] || "",
      openai_chat_endpoint: if(adapter == "openai_chat", do: config["endpoint"] || "", else: ""),
      openclaw_endpoint: if(adapter == "openclaw", do: config["endpoint"] || "", else: ""),
      openclaw_runtime: config["agent_runtime"] || "subagent",
      openclaw_harness_id: config["harness_id"] || ""
    }
  end

  defp default_runtime_form(adapter) do
    provider = default_provider(adapter)
    process_preset = RuntimeOptions.process_default_preset()

    %{
      model: default_model(adapter, provider, process_preset),
      provider: provider,
      command: default_command(adapter, process_preset),
      process_preset: process_preset,
      process_args: "",
      cwd: "",
      openai_chat_endpoint: "",
      openclaw_endpoint: "",
      openclaw_runtime: "subagent",
      openclaw_harness_id: ""
    }
  end

  defp maybe_default_runtime_model(%{model: model} = runtime, "codex", _provider, _preset)
       when is_binary(model) and model != "",
       do: runtime

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

  defp runtime_model_options("openai_chat", _provider, _preset), do: []

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

  defp default_process_value(value, "process", stale_value, preset_value)
       when value in [nil, "", stale_value],
       do: preset_value || value || ""

  defp default_process_value(value, _adapter, _stale_value, _preset_value), do: value || ""

  defp default_model("codex", _provider, _preset),
    do: Cympho.Adapters.CodexAdapter.default_model()

  defp default_model("cursor", _provider, _preset), do: RuntimeOptions.cursor_default_model()

  defp default_model("openai_chat", _provider, _preset), do: "qwen3.7-plus"

  defp default_model("openclaw", provider, _preset),
    do: RuntimeOptions.openclaw_default_model(provider)

  defp default_model("process", provider, _preset) do
    provider
    |> RuntimeOptions.process_model_options()
    |> List.first()
    |> case do
      {_label, value} -> value
      nil -> ""
    end
  end

  defp default_model(_, _provider, _preset), do: ""

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
  defp args_to_text(_args), do: ""

  defp selected_profile_from_params(params) do
    params
    |> Map.get("runtime_profile_id")
    |> RuntimeProfiles.normalize_id()
  end

  defp assign_runtime_profile(socket, profile_id) do
    profile_id = RuntimeProfiles.normalize_id(profile_id)

    socket
    |> assign(:runtime_profiles, RuntimeProfiles.all())
    |> assign(:selected_runtime_profile_id, profile_id)
    |> assign(:runtime_profile, RuntimeProfiles.get!(profile_id))
  end

  defp env_text_from_params(params, profile_id) do
    case Map.get(params, "env_text") do
      text when is_binary(text) ->
        if String.trim(text) == "", do: env_text_from_profile(profile_id), else: text

      _ ->
        env_text_from_profile(profile_id)
    end
  end

  defp env_text_from_profile(profile_id) do
    profile_id
    |> RuntimeProfiles.runtime_config()
    |> Map.get("env", %{})
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map_join("\n", fn {key, value} -> "#{key}=#{value}" end)
  end

  defp normalize_runtime_env(params) do
    case Map.pop(params, "env_text") do
      {nil, params} ->
        params

      {text, params} ->
        env_map = RuntimeEnv.parse_text(text)
        existing = Map.get(params, "runtime_config") || %{}
        runtime_config = Map.put(existing, "env", env_map)
        Map.put(params, "runtime_config", runtime_config)
    end
  end

  defp normalize_parent_id(params) do
    case Map.get(params, "parent_id") do
      "" -> Map.put(params, "parent_id", nil)
      _ -> params
    end
  end

  # When the user changes role, refresh the instructions field if it's still
  # one of the role-template defaults (i.e. they haven't customised it yet).
  # Custom text is left alone so we never overwrite the user's writing.
  defp maybe_refresh_instructions_for_role(%{"role" => role} = params) do
    role_atom = parse_role(role)
    current = Map.get(params, "instructions", "") || ""

    if role_atom != nil and looks_like_default_template?(current) do
      Map.put(params, "instructions", RolePlaybook.default_overrides_template(role_atom))
    else
      params
    end
  end

  defp maybe_refresh_instructions_for_role(params), do: params

  defp parse_role(role) when is_binary(role) do
    Agent.normalize_role(role)
  end

  defp parse_role(_), do: nil

  defp looks_like_default_template?(""), do: true

  defp looks_like_default_template?(text) when is_binary(text) do
    Enum.any?(Agent.role_options(), fn role ->
      RolePlaybook.default_overrides_template(role) == text
    end)
  end

  defp looks_like_default_template?(_), do: false

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

  defp default_adapter(company) do
    if company_openai_chat_ready?(company), do: "openai_chat", else: "claude_code"
  end

  defp company_openai_chat_ready?(%{id: company_id}) do
    present?(company_secret(company_id, "OPENAI_CHAT_ENDPOINT")) and
      present?(company_secret(company_id, "LLMOTIONS_API_KEY"))
  end

  defp company_openai_chat_ready?(_), do: false

  defp maybe_overlay_company_openai_chat(runtime, %{id: company_id}, "openai_chat") do
    endpoint = company_secret(company_id, "OPENAI_CHAT_ENDPOINT")
    model = company_secret(company_id, "OPENAI_CHAT_MODEL")

    runtime
    |> Map.update(:openai_chat_endpoint, "", fn current ->
      if present?(current), do: current, else: endpoint || ""
    end)
    |> Map.update(:model, "", fn current ->
      if present?(current) and current != default_model("openai_chat", nil, nil),
        do: current,
        else: model || current
    end)
  end

  defp maybe_overlay_company_openai_chat(runtime, _company, _adapter), do: runtime

  defp company_secret(company_id, key) do
    case Secrets.get_secret_by_key(company_id, key, scope: "company") do
      {:ok, secret} ->
        case Secrets.get_secret_value(secret.id) do
          {:ok, value} -> value
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp present?(value) when value in [nil, ""], do: false
  defp present?(_value), do: true

  defp normalize_adapter(nil), do: "claude_code"
  defp normalize_adapter(""), do: "claude_code"
  defp normalize_adapter("anthropic"), do: "claude_code"
  defp normalize_adapter("claude"), do: "claude_code"
  defp normalize_adapter(value), do: value

  defp role_label(role), do: Agent.role_label(role)

  def role_avatar_class(role) when is_binary(role) do
    role |> Agent.normalize_role() |> CymphoWeb.Format.role_avatar_class()
  end

  def role_avatar_class(role), do: CymphoWeb.Format.role_avatar_class(role)

  @doc """
  One line of "what this role actually does" so the hire choice is made
  on behavior, not job-title vibes.
  """
  def role_blurb(role) when is_binary(role) do
    role |> Agent.normalize_role() |> role_blurb()
  end

  def role_blurb(:ceo),
    do: "Triages incoming work, sets priorities, and delegates to the right role."

  def role_blurb(:cto),
    do: "Owns technical direction, reviews engineering output, and unblocks delivery."

  def role_blurb(:engineer),
    do: "Picks up coding issues, ships changes as PRs, and reports verified results."

  def role_blurb(:release_engineer),
    do: "Prepares releases, merges verified work, and keeps deploys healthy."

  def role_blurb(:qa_engineer),
    do: "Tests delivered work against acceptance criteria and files regressions."

  def role_blurb(:product_manager),
    do: "Turns goals into scoped issues with clear acceptance criteria."

  def role_blurb(:designer),
    do: "Produces design specs and reviews UI work for consistency."

  def role_blurb(:researcher),
    do: "Investigates questions and returns sourced, decision-ready findings."

  def role_blurb(:marketer),
    do: "Plans and executes growth campaigns with measurable outcomes."

  def role_blurb(:content_strategist),
    do: "Writes and structures content that matches the brand voice."

  def role_blurb(:sales_development),
    do: "Qualifies leads and drafts outreach for the sales pipeline."

  def role_blurb(:customer_support),
    do: "Answers customer issues and escalates product problems with context."

  def role_blurb(_), do: "Works assigned issues and reports progress owners can read."

  @doc "Default reporting line for a role, used as hire-form guidance."
  def role_reports_to_hint(role) when is_binary(role) do
    role |> Agent.normalize_role() |> role_reports_to_hint()
  end

  def role_reports_to_hint(:ceo), do: "Reports to the board"
  def role_reports_to_hint(:cto), do: "Usually reports to the CEO"

  def role_reports_to_hint(role)
      when role in [:engineer, :release_engineer, :qa_engineer],
      do: "Usually reports to the CTO"

  def role_reports_to_hint(_), do: "Usually reports to the CEO"

  defp adapter_label(:claude_code), do: "Claude Code"
  defp adapter_label(:codex), do: "Codex"
  defp adapter_label(:cursor), do: "Cursor"
  defp adapter_label(:http), do: "HTTP"
  defp adapter_label(:openai_chat), do: "OpenAI Chat"
  defp adapter_label(:openclaw), do: "OpenClaw"
  defp adapter_label(:process), do: "Process"
  defp adapter_label(:agrenting), do: "Agrenting"

  defp adapter_label("claude_code"), do: adapter_label(:claude_code)
  defp adapter_label("codex"), do: adapter_label(:codex)
  defp adapter_label("cursor"), do: adapter_label(:cursor)
  defp adapter_label("http"), do: adapter_label(:http)
  defp adapter_label("openai_chat"), do: adapter_label(:openai_chat)
  defp adapter_label("openclaw"), do: adapter_label(:openclaw)
  defp adapter_label("process"), do: adapter_label(:process)
  defp adapter_label("agrenting"), do: adapter_label(:agrenting)
  defp adapter_label(adapter) when is_binary(adapter), do: adapter

  defp runtime_profile_secret_setup_path(%{id: id, adapter: "openai_chat"} = profile, return_to)
       when is_binary(id) do
    keys = openai_chat_credential_keys(profile)
    primary = List.first(keys) || "OPENAI_API_KEY"

    secret_setup_path(
      primary,
      "#{primary} for OpenAI-compatible chat runtime",
      return_to
    )
  end

  defp runtime_profile_secret_setup_path(%{adapter: "claude_code"}, return_to) do
    secret_setup_path(
      "ANTHROPIC_API_KEY",
      "Anthropic-compatible runtime credential",
      return_to
    )
  end

  defp runtime_profile_secret_setup_path(%{adapter: "codex"}, return_to) do
    secret_setup_path(
      "OPENAI_API_KEY",
      "OpenAI or Codex runtime credential",
      return_to
    )
  end

  defp runtime_profile_secret_setup_path(%{adapter: "process"} = profile, return_to) do
    keys =
      RuntimeOptions.process_preset_required_keys(
        profile_config(profile, "process_preset"),
        profile_config(profile, "command")
      )

    case keys do
      [primary | _] ->
        secret_setup_path(primary, "#{primary} runtime credential", return_to)

      _ ->
        nil
    end
  end

  defp runtime_profile_secret_setup_path(_profile, _return_to), do: nil

  defp secret_setup_path(key, description, return_to) do
    query =
      %{
        "key" => key,
        "scope" => "company",
        "description" => description
      }
      |> maybe_put_return_to(return_to)
      |> URI.encode_query()

    "/settings/secrets?#{query}"
  end

  defp maybe_put_return_to(query, return_to) when is_binary(return_to) and return_to != "" do
    case UserAuth.safe_return_path(return_to) do
      nil -> query
      path -> Map.put(query, "return_to", path)
    end
  end

  defp maybe_put_return_to(query, _return_to), do: query

  defp assign_hire_readiness(socket, company, adapter, profile, env_text, runtime) do
    hire_form_path = current_hire_form_path(socket, profile)

    socket
    |> assign(:hire_form_path, hire_form_path)
    |> assign(
      :hire_readiness,
      hire_readiness(company, adapter, profile, env_text, runtime, hire_form_path)
    )
  end

  defp hire_readiness(company, adapter, profile, env_text, runtime, hire_form_path) do
    available_keys = available_credential_keys(company, env_text)
    required_keys = required_provider_keys(adapter, profile, runtime)

    case required_keys do
      [] ->
        # Simple-mode card only — keep free of runtime/adapter jargon.
        ready_hire_readiness(
          "Friendly defaults are ready",
          "This agent starts with the role playbook, company defaults, and safe handoff behavior. No key is required for this setup."
        )

      keys ->
        present_key = Enum.find(keys, &MapSet.member?(available_keys, &1))

        if is_binary(present_key) do
          ready_hire_readiness(
            "Friendly defaults are ready",
            "This agent starts with the role playbook, company defaults, and #{present_key}. Switch to Advanced only when you need to change how it runs."
          )
        else
          primary = List.first(keys)
          setup_path = secret_setup_path(primary, "#{primary} runtime credential", hire_form_path)

          %{
            status: :needs_key,
            label: "Needs a key",
            summary:
              "Add #{primary} before hiring. Without it this agent cannot run, even though the role defaults look complete.",
            primary_key: primary,
            required_keys: keys,
            setup_path: setup_path,
            can_hire: false
          }
        end
    end
  end

  defp current_hire_form_path(socket, profile) do
    form = socket.assigns[:form]
    role = form_field_value(form, :role)
    name = form_field_value(form, :name)
    parent_id = form_field_value(form, :parent_id)
    profile_id = Map.get(profile, :id) || socket.assigns[:selected_runtime_profile_id]

    hire_form_path(%{
      "role" => role,
      "name" => name,
      "parent_id" => parent_id,
      "runtime_profile_id" => profile_id
    })
  end

  defp form_field_value(%Phoenix.HTML.Form{} = form, field) do
    case form[field] do
      %{value: value} when value not in [nil, ""] -> to_string(value)
      _ -> nil
    end
  end

  defp form_field_value(_form, _field), do: nil

  defp ready_hire_readiness(label, summary) do
    %{
      status: :ready,
      label: label,
      summary: summary,
      primary_key: nil,
      required_keys: [],
      setup_path: nil,
      can_hire: true
    }
  end

  defp available_credential_keys(%{id: company_id}, env_text) when is_binary(company_id) do
    secret_keys =
      company_id
      |> Secrets.list_secrets()
      |> Enum.map(& &1.key)
      |> MapSet.new()

    env_keys =
      env_text
      |> RuntimeEnv.parse_text()
      |> Map.keys()
      |> MapSet.new()

    MapSet.union(secret_keys, env_keys)
  end

  defp available_credential_keys(_company, env_text) do
    env_text
    |> RuntimeEnv.parse_text()
    |> Map.keys()
    |> MapSet.new()
  end

  defp required_provider_keys("openai_chat", profile, runtime) do
    openai_chat_credential_keys(%{
      endpoint:
        runtime_value(runtime, :openai_chat_endpoint) || profile_config(profile, "endpoint"),
      model: runtime_value(runtime, :model) || profile_config(profile, "model"),
      id: Map.get(profile, :id)
    })
  end

  defp required_provider_keys("codex", _profile, _runtime),
    do: ["OPENAI_API_KEY", "CODEX_API_KEY"]

  defp required_provider_keys("claude_code", profile, runtime) do
    command =
      first_present([
        runtime_value(runtime, :command),
        profile_config(profile, "command"),
        "claude"
      ])

    RuntimeOptions.process_preset_required_keys("claude_code", command)
  end

  defp required_provider_keys("process", profile, runtime) do
    preset =
      first_present([
        runtime_value(runtime, :process_preset),
        profile_config(profile, "process_preset")
      ])

    command =
      first_present([
        runtime_value(runtime, :command),
        profile_config(profile, "command")
      ])

    RuntimeOptions.process_preset_required_keys(preset, command)
  end

  defp required_provider_keys("agrenting", _profile, _runtime), do: ["AGRENTING_API_KEY"]

  defp required_provider_keys(_adapter, _profile, _runtime), do: []

  defp openai_chat_credential_keys(runtime_or_profile) do
    endpoint =
      runtime_or_profile
      |> runtime_value(:endpoint)
      |> to_string()
      |> String.downcase()

    model =
      runtime_or_profile
      |> runtime_value(:model)
      |> to_string()
      |> String.downcase()

    id =
      runtime_or_profile
      |> runtime_value(:id)
      |> to_string()
      |> String.downcase()

    cond do
      String.contains?(endpoint, "llmotions") or String.contains?(id, "llmotions") ->
        ["LLMOTIONS_API_KEY", "OPENAI_API_KEY", "DASHSCOPE_API_KEY", "ANTHROPIC_API_KEY"]

      String.contains?(endpoint, "dashscope") or String.contains?(id, "dashscope") or
          String.starts_with?(model, "qwen") ->
        ["DASHSCOPE_API_KEY", "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "LLMOTIONS_API_KEY"]

      true ->
        ["OPENAI_API_KEY", "DASHSCOPE_API_KEY", "ANTHROPIC_API_KEY", "LLMOTIONS_API_KEY"]
    end
  end

  defp profile_config(%{config: %{} = config}, key), do: Map.get(config, key)
  defp profile_config(_profile, _key), do: nil

  defp runtime_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp runtime_value(_map, _key), do: nil

  defp first_present(values) do
    Enum.find(values, fn
      value when value in [nil, ""] -> false
      _value -> true
    end)
  end

  defp hire_form_path(params) when is_map(params) do
    query =
      params
      |> Map.take(["role", "name", "parent_id", "runtime_profile_id"])
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
      |> Map.new()

    case URI.encode_query(query) do
      "" -> "/agents/new"
      encoded -> "/agents/new?#{encoded}"
    end
  end

  defp hire_form_path(_params), do: "/agents/new"

  defp issue_example_label(%{identifier: identifier, title: title})
       when is_binary(identifier) and identifier != "" do
    "#{identifier} · #{title}"
  end

  defp issue_example_label(%{title: title}), do: title || "Untitled issue"

  defp plural_noun(1, singular), do: singular
  defp plural_noun(_count, singular), do: singular <> "s"
end
