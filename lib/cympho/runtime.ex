defmodule Cympho.Runtime do
  @moduledoc """
  Runtime preflight for autonomous agent dispatch.

  The dispatcher and orchestrator both use this module to verify that a company,
  agent, adapter, workspace, secrets, and budget are in a runnable state before
  handing work to an external agent process.
  """

  import Ecto.Query, warn: false

  alias Cympho.{
    AgentAdapters,
    Agents,
    Companies,
    Finances,
    Repo,
    RuntimeContext,
    Secrets,
    Workspace,
    Workspaces
  }

  alias Cympho.Agents.Agent
  alias Cympho.Companies.Company
  alias Cympho.Finances.BudgetPolicy
  alias Cympho.Issues.Issue
  alias Cympho.Workspaces.ProjectWorkspace

  @allowed_idle_statuses [:idle]
  @allowed_owned_statuses [:idle, :running]

  @type preflight_error ::
          :not_found
          | :company_paused
          | {:agent_unavailable, atom()}
          | :company_mismatch
          | :no_adapter_available
          | :unknown_adapter
          | {:config_invalid, term()}
          | {:budget_blocked, map()}
          | {:workspace_unavailable, String.t()}
          | {:workspace_error, term()}

  @spec preflight(Issue.t(), Agent.t() | binary(), keyword()) ::
          {:ok, RuntimeContext.t()} | {:error, preflight_error()}
  def preflight(issue, agent_or_id, opts \\ [])

  def preflight(%Issue{} = issue, %Agent{} = agent, opts) do
    with :ok <- verify_company(issue, agent),
         :ok <- verify_agent(agent, issue, opts),
         {:ok, env} <- resolve_env(agent),
         {:ok, adapter, adapter_config} <- resolve_adapter(agent, env, opts),
         {:ok, budget} <- verify_budget(issue, agent),
         {:ok, workspace} <- resolve_workspace(issue, opts) do
      {:ok,
       %RuntimeContext{
         run_id: Keyword.get(opts, :run_id),
         company_id: issue.company_id || agent.company_id,
         project_id: issue.project_id || agent.project_id,
         goal_id: issue.goal_id,
         issue_id: issue.id,
         agent_id: agent.id,
         adapter: adapter,
         adapter_config: put_runtime_config(adapter_config, workspace.cwd, env),
         project_workspace: workspace.project_workspace,
         execution_workspace: workspace.execution_workspace,
         cwd: workspace.cwd,
         env: env,
         skills: Keyword.get(opts, :skills, []),
         budget: budget,
         metadata: %{
           "workspace_source" => workspace.source,
           "preflight_at" => DateTime.utc_now() |> DateTime.to_iso8601()
         }
       }}
    end
  end

  def preflight(%Issue{} = issue, agent_id, opts) when is_binary(agent_id) do
    with {:ok, agent} <- Agents.get_agent(agent_id) do
      preflight(issue, agent, opts)
    end
  end

  @doc """
  Lightweight alias used by the dispatcher before checkout.
  """
  def dispatchable?(%Issue{} = issue, %Agent{} = agent, opts \\ []) do
    case preflight(issue, agent, Keyword.put(opts, :phase, :dispatch)) do
      {:ok, _context} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_company(%Issue{company_id: nil}, %Agent{company_id: nil}), do: :ok

  defp verify_company(%Issue{company_id: nil}, %Agent{company_id: company_id})
       when not is_nil(company_id) do
    verify_company_active(company_id)
  end

  defp verify_company(%Issue{company_id: company_id}, %Agent{company_id: nil})
       when not is_nil(company_id) do
    verify_company_active(company_id)
  end

  defp verify_company(%Issue{company_id: company_id}, %Agent{company_id: company_id}) do
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

  defp verify_agent(%Agent{status: status} = agent, %Issue{} = issue, opts) do
    cond do
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

  defp resolve_env(%Agent{} = agent) do
    {:ok, Secrets.resolve_env_for_agent(agent.id)}
  rescue
    _ -> {:ok, %{}}
  end

  defp resolve_adapter(%Agent{} = agent, env, opts) do
    adapter = Keyword.get(opts, :adapter, agent.adapter) || :claude_code

    config =
      agent
      |> agent_config()
      |> Map.merge(Keyword.get(opts, :adapter_config, %{}) || %{})
      |> with_secret_backed_api_key(adapter, env)

    case AgentAdapters.resolve(%{adapter: adapter, config: config}) do
      {:ok, module, resolved_config} -> {:ok, module, resolved_config}
      {:error, reason} -> {:error, reason}
    end
  end

  defp agent_config(%Agent{} = agent) do
    Map.merge(agent.config || %{}, agent.runtime_config || %{})
  end

  defp with_secret_backed_api_key(config, :codex, env) do
    put_config_new(config, "api_key", env["OPENAI_API_KEY"])
  end

  defp with_secret_backed_api_key(config, :claude_code, env) do
    put_config_new(config, "api_key", env["ANTHROPIC_API_KEY"])
  end

  defp with_secret_backed_api_key(config, :openclaw, env) do
    put_config_new(config, "api_key", env["OPENCLAW_API_KEY"])
  end

  defp with_secret_backed_api_key(config, _adapter, _env), do: config

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
    blocked_policy =
      issue.company_id
      |> Finances.list_budget_policies(is_active: true)
      |> Enum.find(fn policy ->
        policy.action_on_exceed == "block" and policy_applies?(policy, issue, agent) and
          budget_exhausted?(policy)
      end)

    case blocked_policy do
      nil ->
        {:ok, %{status: "available"}}

      %BudgetPolicy{} = policy ->
        {:error,
         {:budget_blocked,
          %{
            policy_id: policy.id,
            scope: policy.scope,
            scope_id: policy.scope_id,
            period: policy.period,
            limit_usd: Decimal.to_string(policy.budget_limit_usd)
          }}}
    end
  end

  defp policy_applies?(%BudgetPolicy{scope: "company"}, _issue, _agent), do: true

  defp policy_applies?(%BudgetPolicy{scope: "agent", scope_id: scope_id}, _issue, agent),
    do: scope_id == agent.id

  defp policy_applies?(%BudgetPolicy{scope: "project", scope_id: scope_id}, issue, _agent),
    do: scope_id == issue.project_id

  defp policy_applies?(%BudgetPolicy{scope: "goal", scope_id: scope_id}, issue, _agent),
    do: scope_id == issue.goal_id

  defp policy_applies?(%BudgetPolicy{scope: "issue", scope_id: scope_id}, issue, _agent),
    do: scope_id == issue.id

  defp policy_applies?(_policy, _issue, _agent), do: false

  defp budget_exhausted?(%BudgetPolicy{} = policy) do
    opts =
      [period: policy.period, from: period_start(policy.period)]
      |> scoped_budget_opts(policy)

    usage = Finances.aggregate_usage(policy.company_id, opts)
    spent = usage[:total_cost] || Decimal.new("0")

    not Decimal.lt?(spent, policy.budget_limit_usd)
  end

  defp scoped_budget_opts(opts, %BudgetPolicy{scope: "company"}), do: opts

  defp scoped_budget_opts(opts, %BudgetPolicy{scope: scope, scope_id: scope_id})
       when scope in ["agent", "project", "goal", "issue"] and not is_nil(scope_id) do
    Keyword.put(opts, String.to_existing_atom("#{scope}_id"), scope_id)
  end

  defp scoped_budget_opts(opts, _policy), do: opts

  defp period_start("daily"), do: DateTime.utc_now() |> DateTime.add(-86_400, :second)
  defp period_start("weekly"), do: DateTime.utc_now() |> DateTime.add(-604_800, :second)
  defp period_start(_monthly), do: DateTime.utc_now() |> DateTime.add(-2_592_000, :second)

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
        case primary_project_workspace(issue.project_id) do
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

  defp primary_project_workspace(project_id) do
    ProjectWorkspace
    |> where([pw], pw.project_id == ^project_id)
    |> order_by([pw], desc: pw.is_primary, asc: pw.inserted_at)
    |> limit(1)
    |> Repo.one()
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
    if File.dir?(cwd) do
      {:ok,
       %{
         cwd: cwd,
         project_workspace: project_workspace,
         execution_workspace: execution_workspace,
         source: source
       }}
    else
      {:error, {:workspace_unavailable, cwd}}
    end
  end

  defp fallback_workspace(%Issue{} = issue) do
    cwd = Workspace.workspace_path(issue.id)

    case File.mkdir_p(cwd) do
      :ok ->
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

  defp put_runtime_config(config, cwd, env) do
    config
    |> Map.put_new("cwd", cwd)
    |> Map.update("env", env, fn existing -> Map.merge(existing || %{}, env) end)
  end
end
