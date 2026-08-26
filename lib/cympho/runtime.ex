defmodule Cympho.Runtime do
  @moduledoc """
  Runtime preflight for autonomous agent dispatch.

  The dispatcher and orchestrator both use this module to verify that a company,
  agent, adapter, workspace, secrets, and budget are in a runnable state before
  handing work to an external agent process.
  """

  import Ecto.Query, warn: false

  alias Cympho.{
    Adapters,
    Agents,
    Companies,
    Finances,
    Projects,
    Repo,
    RuntimeAdmission,
    RuntimeContext,
    Secrets,
    Workspace,
    Workspaces
  }

  alias Cympho.Agents.Agent
  alias Cympho.Companies.Company
  alias Cympho.Issues.Issue
  alias Cympho.Workspaces.ProjectWorkspace

  require Logger

  @allowed_idle_statuses [:idle]
  @allowed_owned_statuses [:idle, :running]
  @repo_delivery_roles Agent.pr_delivery_roles()

  @type preflight_error ::
          :not_found
          | :company_paused
          | {:agent_unavailable, atom()}
          | :company_mismatch
          | :no_adapter_available
          | :unknown_adapter
          | {:config_invalid, term()}
          | {:adapter_model_mismatch, String.t()}
          | {:budget_blocked, map()}
          | {:workspace_unavailable, String.t()}
          | {:workspace_error, term()}
          | {:environment_provider_error, term()}
          | {:repo_delivery_runtime_unavailable, atom()}
          | {:stage_gate_blocked, atom()}
          | :missing_api_key

  @spec preflight(Issue.t(), Agent.t() | binary(), keyword()) ::
          {:ok, RuntimeContext.t()} | {:error, preflight_error()}
  def preflight(issue, agent_or_id, opts \\ [])

  def preflight(%Issue{} = issue, %Agent{} = agent, opts) do
    with {:ok, %{env: env, adapter: adapter, adapter_config: adapter_config, budget: budget}} <-
           verify_eligibility(issue, agent, opts),
         {:ok, workspace} <- resolve_workspace(issue, opts),
         {:ok, workspace} <- ensure_provider_environment(workspace) do
      runtime_env = Map.merge(env, runtime_identity_env(issue, agent, workspace, opts))

      {:ok,
       %RuntimeContext{
         run_id: Keyword.get(opts, :run_id),
         company_id: issue.company_id || agent.company_id,
         project_id: issue.project_id || agent.project_id,
         goal_id: issue.goal_id,
         issue_id: issue.id,
         agent_id: agent.id,
         adapter: adapter,
         adapter_config: put_runtime_config(adapter_config, workspace.cwd, runtime_env),
         project_workspace: workspace.project_workspace,
         execution_workspace: workspace.execution_workspace,
         cwd: workspace.cwd,
         env: runtime_env,
         skills: Keyword.get(opts, :skills, []),
         budget: budget,
         metadata: runtime_metadata(issue, workspace, opts)
       }}
    end
  end

  def preflight(%Issue{} = issue, agent_id, opts) when is_binary(agent_id) do
    with {:ok, agent} <- Agents.get_agent(agent_id) do
      preflight(issue, agent, opts)
    end
  end

  @doc """
  Lightweight eligibility check used by the dispatcher before checkout.

  This deliberately stops short of `resolve_workspace/2` and
  `ensure_provider_environment/1`. Those are the expensive parts — a blocking
  `git clone` and a remote environment acquisition — and they run inside the
  single global Dispatcher GenServer, where one large repository or one hung
  provider stalls dispatch for every tenant. The orchestrator runs the full
  `preflight/3` in its own process when it starts the session, so doing that
  work here bought nothing and blocked everyone.
  """
  def dispatchable?(%Issue{} = issue, %Agent{} = agent, opts \\ []) do
    case verify_eligibility(issue, agent, opts) do
      {:ok, %{adapter: adapter}} ->
        case RuntimeAdmission.available(adapter) do
          :ok -> :ok
          {:error, reason} -> {:error, {:runtime_admission_deferred, reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The checks that decide whether an issue *may* run, with no side effects on
  # the filesystem or a remote provider.
  defp verify_eligibility(%Issue{} = issue, %Agent{} = agent, opts) do
    with :ok <- verify_company(issue, agent),
         :ok <- verify_agent(agent, issue, opts),
         :ok <- verify_repo_delivery_runtime(issue, agent),
         :ok <- verify_stage_gate(issue, agent),
         {:ok, env} <- resolve_env(agent, opts),
         {:ok, adapter, adapter_config} <- resolve_adapter(agent, env, opts),
         {:ok, budget} <- verify_budget(issue, agent) do
      {:ok, %{env: env, adapter: adapter, adapter_config: adapter_config, budget: budget}}
    end
  end

  @doc """
  Resolves the adapter module and config an agent would use at runtime.

  This is intentionally lighter than `preflight/3`: it does not reserve
  capacity, resolve workspaces, or check budgets. It exists for read-only
  diagnostics like adapter health checks that must evaluate the same
  secret-backed config a real run would receive.

  Options:
    * `:validate_config?` - validates adapter config before returning. Defaults
      to `true`; diagnostics can set it to `false` so the adapter's own
      `health_check/1` can return a nuanced status.
  """
  @spec resolve_adapter_config(Agent.t(), keyword()) ::
          {:ok, module(), map()} | {:error, term()}
  def resolve_adapter_config(%Agent{} = agent, opts \\ []) do
    with {:ok, env} <- resolve_env(agent, opts),
         {:ok, adapter, adapter_config} <- resolve_adapter(agent, env, opts) do
      {:ok, adapter, adapter_config}
    end
  end

  # Fail-closed: both issue and agent must share a non-blank company_id.
  # A nil/empty on either side must not pass preflight.
  defp verify_company(%Issue{company_id: company_id}, %Agent{company_id: company_id})
       when is_binary(company_id) and company_id != "" do
    verify_company_active(company_id)
  end

  defp verify_company(_issue, _agent), do: {:error, :company_mismatch}

  defp verify_company_active(company_id) do
    case Repo.get(Company, company_id) do
      nil ->
        {:error, :not_found}

      %Company{} = company ->
        if Companies.active?(company), do: :ok, else: {:error, :company_paused}
    end
  end

  defp verify_stage_gate(%Issue{execution_policy_id: nil}, _agent), do: :ok

  defp verify_stage_gate(%Issue{execution_state: state}, _agent)
       when state == %{} or is_nil(state),
       do: :ok

  defp verify_stage_gate(%Issue{} = issue, %Agent{} = agent) do
    alias Cympho.Issues.ExecutionState
    alias Cympho.ExecutionPolicies

    state = ExecutionState.normalize(issue.execution_state)

    if ExecutionState.active?(state) do
      case ExecutionPolicies.get_execution_policy(issue.execution_policy_id) do
        {:ok, policy} ->
          cond do
            ExecutionState.require_human?(state, policy) ->
              {:error, {:stage_gate_blocked, :require_human}}

            not ExecutionState.stage_complete?(state) and
                Map.get(state, :current_participant) != agent.id ->
              {:error, {:stage_gate_blocked, :stage_incomplete}}

            true ->
              :ok
          end

        {:error, _} ->
          :ok
      end
    else
      :ok
    end
  end

  defp verify_agent(%Agent{status: status} = agent, %Issue{} = issue, opts) do
    cond do
      # Checked ahead of `skip_agent_status?` on purpose: that flag exists to
      # relax the *operational* status for an owned run, not to let a paused or
      # terminated agent through. Governance writers leave `status` untouched,
      # so this is the only field that reflects a governance stop.
      not Agents.governance_active?(agent) ->
        {:error, {:agent_governance_blocked, agent.governance_status}}

      Keyword.get(opts, :skip_agent_status?, false) ->
        :ok

      status in @allowed_idle_statuses ->
        :ok

      status in @allowed_owned_statuses and issue.assignee_id == agent.id ->
        :ok

      true ->
        {:error, {:agent_unavailable, status}}
    end
  end

  defp verify_repo_delivery_runtime(%Issue{} = issue, %Agent{} = agent) do
    role = Cympho.Orchestrator.Dispatcher.Router.infer_role(issue)

    if role in @repo_delivery_roles and
         not Cympho.AgentRuntimeCapabilities.repo_delivery_capable?(agent,
           load_secret_keys?: true
         ) do
      {:error, {:repo_delivery_runtime_unavailable, role}}
    else
      :ok
    end
  end

  defp resolve_env(%Agent{} = agent, opts) do
    profile_env = normalize_env(Keyword.get(opts, :runtime_env, %{}))
    config_env = Cympho.Agents.RuntimeEnv.from_agent(agent)
    secrets_env = safe_resolve_secrets_env(agent.id)
    {:ok, profile_env |> Map.merge(config_env) |> Map.merge(secrets_env)}
  end

  defp normalize_env(env) when is_map(env) do
    Map.new(env, fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  defp normalize_env(_), do: %{}

  defp safe_resolve_secrets_env(agent_id) do
    Secrets.resolve_env_for_agent(agent_id)
  rescue
    error ->
      # Log the failure so silent secret-resolution errors are visible. We
      # only log the exception message — never the raised value itself, in
      # case it carries secret material in its struct fields.
      Logger.error(
        "[Runtime] secret resolution failed for agent #{agent_id}: #{Exception.message(error)}"
      )

      %{}
  end

  defp resolve_adapter(%Agent{} = agent, env, opts) do
    adapter = Keyword.get(opts, :adapter, agent.adapter) || :claude_code

    config =
      agent
      |> agent_config()
      |> Map.merge(Keyword.get(opts, :adapter_config, %{}) || %{})

    case with_secret_backed_api_key(config, adapter, env) do
      {:error, :missing_api_key} = error ->
        error

      config when is_map(config) ->
        if Keyword.get(opts, :validate_config?, true) do
          case Adapters.resolve(%{adapter: adapter, config: config}) do
            {:ok, module, resolved_config} ->
              case Adapters.ModelCompatibility.validate(module, resolved_config) do
                :ok -> {:ok, module, resolved_config}
                {:error, message} -> {:error, {:adapter_model_mismatch, message}}
              end

            {:error, reason} ->
              {:error, reason}
          end
        else
          case Adapters.Registry.resolve_agent(%{adapter: adapter, config: config}) do
            {:ok, module, resolved_config} -> {:ok, module, resolved_config}
            {:error, :no_adapter} -> {:error, :no_adapter_available}
          end
        end
    end
  end

  defp agent_config(%Agent{} = agent) do
    Map.merge(agent.config || %{}, agent.runtime_config || %{})
  end

  defp with_secret_backed_api_key(config, :codex, env) do
    api_key =
      env["OPENAI_API_KEY"] ||
        if(llmotions_codex?(config), do: env["LLMOTIONS_API_KEY"])

    put_config_new(config, "api_key", api_key)
  end

  defp with_secret_backed_api_key(config, :claude_code, env) do
    put_config_new(config, "api_key", env["ANTHROPIC_API_KEY"])
  end

  defp with_secret_backed_api_key(config, :openclaw, env) do
    put_config_new(config, "api_key", env["OPENCLAW_API_KEY"])
  end

  defp with_secret_backed_api_key(config, :openai_chat, env) do
    endpoint = openai_chat_endpoint(config, env)
    model = openai_chat_model(config, env)
    existing_key = config_value(config, "api_key")
    host = endpoint_host(endpoint)

    cond do
      openai_company_key_host_allowed?(host, env) ->
        config
        |> put_config_new("api_key", openai_chat_api_key(endpoint, model, env))
        |> put_config_new("endpoint", endpoint)
        |> put_config_new("model", model)

      present_api_key?(existing_key) ->
        config
        |> put_config_new("endpoint", endpoint)
        |> put_config_new("model", model)

      true ->
        {:error, :missing_api_key}
    end
  end

  defp with_secret_backed_api_key(config, :agrenting, env) do
    config
    |> put_config_new("api_key", env["AGRENTING_API_KEY"])
    |> put_config_new("base_url", env["AGRENTING_URL"])
    |> put_config_new(
      "repo_access_token",
      env["AGRENTING_REPO_ACCESS_TOKEN"] || env["GITHUB_TOKEN"]
    )
  end

  defp with_secret_backed_api_key(config, _adapter, _env), do: config

  defp openai_chat_api_key(endpoint, model, env) do
    cond do
      llmotions_chat?(endpoint, model) ->
        first_env(env, [
          "LLMOTIONS_API_KEY",
          "OPENAI_API_KEY",
          "DASHSCOPE_API_KEY",
          "ANTHROPIC_API_KEY"
        ])

      dashscope_chat?(endpoint, model) ->
        first_env(env, [
          "DASHSCOPE_API_KEY",
          "OPENAI_API_KEY",
          "ANTHROPIC_API_KEY",
          "LLMOTIONS_API_KEY"
        ])

      true ->
        first_env(env, [
          "OPENAI_API_KEY",
          "DASHSCOPE_API_KEY",
          "ANTHROPIC_API_KEY",
          "LLMOTIONS_API_KEY"
        ])
    end
  end

  defp openai_chat_endpoint(config, env) do
    config_value(config, "endpoint") ||
      config_value(config, "base_url") ||
      env["LLMOTIONS_BASE_URL"] ||
      env["OPENAI_BASE_URL"] ||
      env["DASHSCOPE_BASE_URL"] ||
      env["ANTHROPIC_BASE_URL"]
  end

  defp openai_chat_model(config, env) do
    config_value(config, "model") ||
      env["LLMOTIONS_MODEL"] ||
      env["OPENAI_MODEL"] ||
      env["DASHSCOPE_MODEL"] ||
      env["MODEL"]
  end

  defp first_env(env, keys) do
    Enum.find_value(keys, fn key ->
      value = env[key]
      if value in [nil, ""], do: nil, else: value
    end)
  end

  @openai_company_key_hosts ["api.openai.com", "api.anthropic.com"]
  @recorded_provider_hosts ["cli.llmotions.com", "api.llmotions.com"]

  defp openai_company_key_host_allowed?(host, env) when is_binary(host) do
    host in @openai_company_key_hosts or
      String.ends_with?(host, ".aliyuncs.com") or
      host in @recorded_provider_hosts or
      host in recorded_secret_provider_hosts(env)
  end

  defp openai_company_key_host_allowed?(_host, _env), do: false

  defp recorded_secret_provider_hosts(env) when is_map(env) do
    ~w(OPENAI_BASE_URL DASHSCOPE_BASE_URL ANTHROPIC_BASE_URL LLMOTIONS_BASE_URL)
    |> Enum.map(&endpoint_host(env[&1]))
    |> Enum.reject(&is_nil/1)
  end

  defp recorded_secret_provider_hosts(_env), do: []

  defp endpoint_host(endpoint) when is_binary(endpoint) do
    case URI.parse(String.trim(endpoint)) do
      %URI{host: host} when is_binary(host) and host != "" -> String.downcase(host)
      _ -> nil
    end
  end

  defp endpoint_host(_endpoint), do: nil

  defp present_api_key?(key) when is_binary(key), do: String.trim(key) != ""
  defp present_api_key?(_key), do: false

  defp config_value(config, key) when is_map(config) do
    Map.get(config, key) || Map.get(config, String.to_atom(key))
  end

  defp llmotions_chat?(endpoint, model) do
    text = "#{endpoint} #{model}" |> String.downcase()
    String.contains?(text, "llmotions")
  end

  defp llmotions_codex?(config) do
    endpoint = config_value(config, "base_url") || config_value(config, "endpoint")
    is_binary(endpoint) and String.contains?(String.downcase(endpoint), "llmotions")
  end

  defp dashscope_chat?(endpoint, model) do
    text = "#{endpoint} #{model}" |> String.downcase()
    String.contains?(text, "dashscope") or String.contains?(text, "qwen")
  end

  defp put_config_new(config, _key, nil), do: config
  defp put_config_new(config, _key, ""), do: config

  defp put_config_new(config, key, value) do
    if Map.has_key?(config, key) or Map.has_key?(config, String.to_atom(key)) do
      config
    else
      Map.put(config, key, value)
    end
  end

  defp verify_budget(%Issue{company_id: nil}, _agent), do: {:ok, %{status: "unscoped"}}

  defp verify_budget(%Issue{} = issue, %Agent{} = agent) do
    Finances.check_runtime_budget(issue, agent)
  end

  defp resolve_workspace(%Issue{} = issue, opts) do
    cond do
      Keyword.get(opts, :cwd) ->
        ensure_configured_cwd(Keyword.fetch!(opts, :cwd), nil, nil, "override")

      issue.execution_workspace_id ->
        with {:ok, execution_workspace} <-
               Workspaces.get_execution_workspace(issue.execution_workspace_id) do
          project_workspace =
            maybe_get_project_workspace(execution_workspace.project_workspace_id)

          ensure_configured_cwd(
            execution_workspace.cwd,
            project_workspace,
            execution_workspace,
            "execution_workspace"
          )
        end

      issue.project_workspace_id ->
        with {:ok, project_workspace} <-
               Workspaces.get_project_workspace(issue.project_workspace_id) do
          ensure_configured_cwd(
            project_workspace.cwd,
            project_workspace,
            nil,
            "project_workspace"
          )
        end

      issue.project_id ->
        case Workspaces.primary_project_workspace(issue.project_id) do
          %ProjectWorkspace{} = project_workspace ->
            ensure_configured_cwd(
              project_workspace.cwd,
              project_workspace,
              nil,
              "project_workspace"
            )

          nil ->
            fallback_workspace(issue)
        end

      true ->
        fallback_workspace(issue)
    end
  end

  defp maybe_get_project_workspace(nil), do: nil

  defp maybe_get_project_workspace(id) do
    case Workspaces.get_project_workspace(id) do
      {:ok, project_workspace} -> project_workspace
      {:error, _} -> nil
    end
  end

  defp ensure_configured_cwd(nil, _project_workspace, _execution_workspace, _source),
    do: {:error, {:workspace_unavailable, "missing cwd"}}

  defp ensure_configured_cwd(cwd, project_workspace, execution_workspace, source) do
    if Workspace.safe_host_cwd?(cwd) and File.dir?(Path.expand(cwd)) do
      {:ok,
       %{
         cwd: Path.expand(cwd),
         project_workspace: project_workspace,
         execution_workspace: execution_workspace,
         source: source
       }}
    else
      {:error, {:workspace_unavailable, cwd}}
    end
  end

  # When the execution workspace names a remote provider, acquire (or reuse)
  # via EnvironmentLifecycle / Fake driver and persist provider_ref.
  # Blank provider_type stays local; unknown providers fail closed.
  defp ensure_provider_environment(%{execution_workspace: nil} = workspace), do: {:ok, workspace}

  defp ensure_provider_environment(%{execution_workspace: ew} = workspace) do
    case Workspaces.ensure_provider_environment(ew) do
      {:ok, updated} ->
        {:ok, %{workspace | execution_workspace: updated}}

      {:error, reason} ->
        {:error, {:environment_provider_error, reason}}
    end
  end

  defp fallback_workspace(%Issue{} = issue) do
    case Workspace.ensure_for_issue(issue) do
      {:ok, cwd} ->
        {:ok,
         %{
           cwd: cwd,
           project_workspace: nil,
           execution_workspace: nil,
           source: "issue_workspace"
         }}

      {:error, reason} ->
        {:error, {:workspace_error, reason}}
    end
  end

  defp runtime_identity_env(%Issue{} = issue, %Agent{} = agent, workspace, opts) do
    provider_ref =
      case workspace do
        %{execution_workspace: %{provider_ref: ref}} when is_binary(ref) and ref != "" -> ref
        _ -> nil
      end

    [
      {"CYMPHO_RUN_ID", Keyword.get(opts, :run_id)},
      {"CYMPHO_COMPANY_ID", issue.company_id || agent.company_id},
      {"CYMPHO_PROJECT_ID", issue.project_id || agent.project_id},
      {"CYMPHO_GOAL_ID", issue.goal_id},
      {"CYMPHO_ISSUE_ID", issue.id},
      {"CYMPHO_AGENT_ID", agent.id},
      {"CYMPHO_WORKSPACE", workspace.cwd},
      {"CYMPHO_PROVIDER_REF", provider_ref},
      {"AGENT_HOME", workspace.cwd}
    ]
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new(fn {key, value} -> {key, to_string(value)} end)
  end

  defp runtime_metadata(%Issue{} = issue, workspace, opts) do
    metadata = %{
      "runtime_profile_id" => Keyword.get(opts, :runtime_profile_id),
      "workspace_source" => workspace.source,
      "preflight_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    metadata =
      case workspace do
        %{execution_workspace: %{provider_type: type, provider_ref: ref}}
        when is_binary(type) and type != "" ->
          metadata
          |> Map.put("provider_type", type)
          |> Map.put("provider_ref", ref)

        _ ->
          metadata
      end

    case configured_project_repository_fingerprint(issue) do
      {:ok, fingerprint} -> Map.put(metadata, "project_repository_fingerprint", fingerprint)
      :error -> metadata
    end
  end

  defp configured_project_repository_fingerprint(%Issue{project_id: project_id})
       when is_binary(project_id) do
    with {:ok, project} <- Projects.get_project(project_id),
         repo_url when is_binary(repo_url) and repo_url != "" <- project_repository_url(project),
         {:ok, fingerprint} <- Workspace.repository_fingerprint(repo_url) do
      {:ok, fingerprint}
    else
      _reason -> :error
    end
  end

  defp configured_project_repository_fingerprint(_issue), do: :error

  defp project_repository_url(%{repo_url: repo_url})
       when is_binary(repo_url) and repo_url != "",
       do: repo_url

  defp project_repository_url(%{settings: %{"repo_url" => repo_url}})
       when is_binary(repo_url) and repo_url != "",
       do: repo_url

  defp project_repository_url(_project), do: nil

  defp put_runtime_config(config, cwd, env) do
    config
    |> Map.put_new("cwd", cwd)
    |> Map.put_new("workspace_path", cwd)
    |> Map.update("env", env, fn existing -> Map.merge(existing || %{}, env) end)
  end
end
