defmodule CymphoWeb.AgentLive.New do
  use CymphoWeb, :live_view
  alias Cympho.Agents
  alias Cympho.Agents.Agent
  alias Cympho.Agents.RolePlaybook
  alias Cympho.Agents.RuntimeEnv
  alias Cympho.Adapters.RuntimeOptions

  @default_role "engineer"

  @default_attrs %{
    "role" => @default_role,
    "adapter" => "claude_code",
    "max_concurrent_jobs" => "3",
    "instructions" => RolePlaybook.default_overrides_template(:engineer)
  }

  @impl true
  def mount(_params, _session, socket) do
    company = socket.assigns[:current_company]
    attrs = maybe_put_company_id(@default_attrs, company)
    changeset = Agents.change_agent(%Agent{}, attrs)

    {:ok,
     socket
     |> assign(:page_title, "New Agent")
     |> assign(:pending_approval_id, nil)
     |> assign(:env_text, "")
     |> assign(:selected_adapter, "claude_code")
     |> assign_runtime_form(default_runtime_form("claude_code"))
     |> assign(:reports_to_options, reports_to_options(company, nil))
     |> assign(:form, to_form(changeset))}
  end

  @impl true
  def handle_event("validate", %{"agent" => agent_params}, socket) do
    company = socket.assigns[:current_company]

    agent_params = maybe_refresh_instructions_for_role(agent_params)
    env_text = Map.get(agent_params, "env_text", "")
    selected_adapter = selected_adapter_from_params(agent_params)
    runtime = runtime_form_from_params(agent_params, selected_adapter)

    changeset =
      %Agent{}
      |> Agents.change_agent(
        agent_params
        |> maybe_put_adapter_config(selected_adapter, runtime)
        |> normalize_agent_params()
        |> maybe_put_company_id(company)
      )
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:env_text, env_text)
     |> assign(:selected_adapter, selected_adapter)
     |> assign_runtime_form(runtime)
     |> assign(:form, to_form(changeset))}
  end

  def handle_event("save", %{"agent" => agent_params}, socket) do
    company = socket.assigns[:current_company]
    selected_adapter = selected_adapter_from_params(agent_params)
    runtime = runtime_form_from_params(agent_params, selected_adapter)

    params =
      agent_params
      |> maybe_put_adapter_config(selected_adapter, runtime)
      |> normalize_agent_params()
      |> maybe_put_company_id(company)

    case Agents.create_agent(params) do
      {:ok, _agent} ->
        {:noreply, push_navigate(socket, to: ~p"/agents")}

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
         |> assign_runtime_form(runtime)
         |> assign(form: to_form(Map.put(changeset, :action, :insert)))}
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

  def codex_model_options, do: Cympho.Adapters.CodexAdapter.model_options()
  def cursor_model_options, do: RuntimeOptions.cursor_model_options()
  def openclaw_provider_options, do: RuntimeOptions.openclaw_provider_options()
  def openclaw_provider_model_options, do: RuntimeOptions.openclaw_provider_model_options()
  def openclaw_model_options(provider), do: RuntimeOptions.openclaw_model_options(provider)
  def process_preset_options, do: RuntimeOptions.process_preset_options()
  def process_provider_options, do: RuntimeOptions.process_provider_options()
  def process_provider_model_options, do: RuntimeOptions.process_provider_model_options()
  def process_model_options(provider), do: RuntimeOptions.process_model_options(provider)

  defp maybe_put_company_id(params, %{id: company_id}) do
    Map.put(params, "company_id", company_id)
  end

  defp maybe_put_company_id(params, _), do: params

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
      "openclaw_harness_id"
    ])
    |> normalize_parent_id()
    |> normalize_runtime_env()
  end

  defp selected_adapter_from_params(params) do
    params
    |> Map.get("adapter", "claude_code")
    |> normalize_adapter()
  end

  defp maybe_put_adapter_config(params, adapter, runtime) do
    config =
      params
      |> Map.get("config", %{})
      |> build_adapter_config(adapter, runtime)

    Map.put(params, "config", config)
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

  defp put_clean(map, _key, value) when value in [nil, ""], do: map
  defp put_clean(map, key, value), do: Map.put(map, key, value)

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

  defp runtime_form_from_params(params, adapter) do
    fallback = default_runtime_form(adapter)

    provider =
      params
      |> param_string("provider", fallback.provider)
      |> default_runtime_provider(adapter)

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
    |> maybe_default_runtime_model(adapter, provider, process_preset)
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
      openclaw_endpoint: "",
      openclaw_runtime: "subagent",
      openclaw_harness_id: ""
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

  defp default_model("codex", _provider, _preset),
    do: Cympho.Adapters.CodexAdapter.default_model()

  defp default_model("cursor", _provider, _preset), do: RuntimeOptions.cursor_default_model()

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
    case role do
      "ceo" -> :ceo
      "cto" -> :cto
      "engineer" -> :engineer
      "product_manager" -> :product_manager
      "designer" -> :designer
      _ -> nil
    end
  end

  defp parse_role(_), do: nil

  defp looks_like_default_template?(""), do: true

  defp looks_like_default_template?(text) when is_binary(text) do
    Enum.any?([:ceo, :cto, :engineer, :product_manager, :designer], fn role ->
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

  defp normalize_adapter(nil), do: "claude_code"
  defp normalize_adapter(""), do: "claude_code"
  defp normalize_adapter("anthropic"), do: "claude_code"
  defp normalize_adapter("claude"), do: "claude_code"
  defp normalize_adapter(value), do: value

  defp role_label(:ceo), do: "CEO"
  defp role_label(:cto), do: "CTO"
  defp role_label(:product_manager), do: "Product Manager"
  defp role_label(:engineer), do: "Engineer"
  defp role_label(:designer), do: "Designer"

  defp adapter_label(:claude_code), do: "Claude Code"
  defp adapter_label(:codex), do: "Codex"
  defp adapter_label(:cursor), do: "Cursor"
  defp adapter_label(:http), do: "HTTP"
  defp adapter_label(:openclaw), do: "OpenClaw"
  defp adapter_label(:process), do: "Process"
end
