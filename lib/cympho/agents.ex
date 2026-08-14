defmodule Cympho.Agents do
  @moduledoc """
  The Agents context manages agent entities and their lifecycle.
  """

  import Ecto.Query, warn: false
  alias Cympho.Repo
  alias Cympho.Agents.Agent
  alias Cympho.Agents.AgentConfigRevision
  alias Cympho.AgentInstructionStudio
  alias Cympho.BoardApprovals
  alias Cympho.Issues.Issue

  # Hard upper bound for unscoped agent listings. Real installs have far
  # fewer agents than this; the cap exists to prevent an unbounded `Repo.all`
  # from OOMing the node if data ever grows past expectations.
  @list_agents_safety_cap 5_000

  def temporary?(%Agent{} = agent) do
    truthy_config?(agent.config, "temporary") or
      truthy_config?(agent.config, "one_time") or
      truthy_config?(agent.runtime_config, "temporary") or
      truthy_config?(agent.runtime_config, "one_time") or
      truthy_config?(get_in(agent.runtime_config || %{}, ["swarm"]), "temporary")
  end

  @doc """
  Returns the list of all agents, capped at #{@list_agents_safety_cap} rows.

  Prefer `list_agents_by_company/1` whenever a company context is available.
  """
  def list_agents do
    Agent
    |> exclude_temporary()
    |> limit(@list_agents_safety_cap)
    |> Repo.all()
  end

  @doc """
  Returns agents belonging to a company.
  """
  def list_agents_by_company(company_id) do
    Agent
    |> where(company_id: ^company_id)
    |> exclude_temporary()
    |> order_by([a],
      asc: fragment("CASE ? WHEN 'ceo' THEN 0 WHEN 'cto' THEN 1 ELSE 2 END", a.role),
      asc: a.inserted_at
    )
    |> Repo.all()
  end

  @doc """
  Returns the first active CEO agent for a company.
  """
  def get_company_ceo(company_id) do
    case Repo.one(
           from a in Agent,
             where:
               a.company_id == ^company_id and a.role == :ceo and
                 a.governance_status != "terminated",
             order_by: [asc: a.inserted_at, asc: a.id],
             limit: 1
         ) do
      nil -> {:error, :not_found}
      agent -> {:ok, agent}
    end
  end

  @doc """
  Returns the first active CTO agent for a company.
  """
  def get_company_cto(company_id) do
    case Repo.one(
           from a in Agent,
             where:
               a.company_id == ^company_id and a.role == :cto and
                 a.governance_status != "terminated",
             order_by: [asc: a.inserted_at, asc: a.id],
             limit: 1
         ) do
      nil -> {:error, :not_found}
      agent -> {:ok, agent}
    end
  end

  @doc """
  Sidebar projection: id, name, role, status.
  CEO/CTO pinned at top, then alphabetical. Excludes terminated agents.
  """
  def list_for_sidebar(company_id) do
    Agent
    |> where(
      [a],
      a.company_id == ^company_id and a.governance_status != "terminated"
    )
    |> exclude_temporary()
    |> order_by([a],
      asc: fragment("CASE ? WHEN 'ceo' THEN 0 WHEN 'cto' THEN 1 ELSE 2 END", a.role),
      asc: a.name
    )
    |> select([a], %{id: a.id, name: a.name, role: a.role, status: a.status})
    |> Repo.all()
  end

  @doc """
  Returns agents with the specified role.
  """
  def list_agents_by_role(role) when is_atom(role) do
    Agent
    |> where(role: ^role)
    |> exclude_temporary()
    |> Repo.all()
  end

  @doc """
  Returns agents with the specified role, scoped to a company.
  """
  def list_agents_by_role(role, company_id) when is_atom(role) and is_binary(company_id) do
    Agent
    |> where(role: ^role, company_id: ^company_id)
    |> exclude_temporary()
    |> Repo.all()
  end

  @doc """
  Returns agents with the specified status.
  """
  def list_agents_by_status(status) when is_atom(status) do
    Agent
    |> where(status: ^status)
    |> exclude_temporary()
    |> Repo.all()
  end

  def list_agents_by_status(status, company_id) when is_atom(status) do
    Agent
    |> where(status: ^status, company_id: ^company_id)
    |> exclude_temporary()
    |> Repo.all()
  end

  @doc """
  Returns agents with the specified adapter type, scoped to a company.
  """
  def list_agents_by_adapter(adapter, company_id)
      when is_atom(adapter) and is_binary(company_id) do
    Agent
    |> where(adapter: ^adapter, company_id: ^company_id)
    |> exclude_temporary()
    |> Repo.all()
  end

  @doc """
  Returns the list of valid adapter types.
  """
  def adapter_options, do: Agent.adapter_options()

  @doc """
  Gets a single agent by id.
  """
  def get_agent!(id), do: Repo.get!(Agent, id)

  @doc """
  Gets a single agent by id, returns {:ok, agent} or {:error, :not_found}.
  """
  def get_company_agent(company_id, id) do
    with {:ok, company_id} <- Ecto.UUID.cast(company_id),
         {:ok, id} <- Ecto.UUID.cast(id) do
      case Repo.one(from a in Agent, where: a.id == ^id and a.company_id == ^company_id) do
        nil -> {:error, :not_found}
        agent -> if temporary?(agent), do: {:error, :not_found}, else: {:ok, agent}
      end
    else
      :error -> {:error, :not_found}
    end
  end

  def get_agent(id) do
    case Repo.get(Agent, id) do
      nil -> {:error, :not_found}
      agent -> {:ok, agent}
    end
  end

  @doc """
  Creates an agent.
  If governance requires approval for agent_hire, creates a BoardApproval instead
  and returns `{:error, :pending_board_approval, approval_id}`.
  """
  def create_agent(attrs \\ %{}) do
    with :ok <- maybe_require_hire_approval(attrs) do
      do_create_agent(attrs)
    end
  end

  def do_create_agent(attrs) do
    %Agent{}
    |> Agent.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, agent} ->
        Cympho.PubSubGuard.company_broadcast(
          agent.company_id,
          "agents",
          {:agent_created, agent}
        )

        {:ok, agent}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Updates an agent.
  If the role is changing and governance requires approval, creates a BoardApproval
  and returns `{:error, :pending_board_approval, approval_id}`.
  """
  def update_agent(%Agent{} = agent, attrs) do
    with :ok <- maybe_require_role_change_approval(agent, attrs) do
      do_update_agent(agent, attrs)
    end
  end

  @doc """
  Atomically replaces the config map for a set of agents.

  This is intended for trusted bulk configuration flows where every update
  must commit together. Agent update broadcasts are emitted only after the
  transaction succeeds.
  """
  @spec update_adapter_configs([{Agent.t(), map()}]) ::
          {:ok, [Agent.t()]} | {:error, binary(), term()}
  def update_adapter_configs(updates) when is_list(updates) do
    multi =
      Enum.reduce(updates, Ecto.Multi.new(), fn {%Agent{} = agent, config}, multi ->
        changeset = Agent.update_changeset(agent, %{config: config})
        Ecto.Multi.update(multi, {:agent_config, agent.id}, changeset, stale_error_field: :id)
      end)

    case Repo.transaction(multi) do
      {:ok, changes} ->
        updated_agents =
          Enum.map(updates, fn {agent, _config} ->
            Map.fetch!(changes, {:agent_config, agent.id})
          end)

        Enum.each(updated_agents, fn updated ->
          Cympho.PubSubGuard.company_broadcast(
            updated.company_id,
            "agents",
            {:agent_updated, updated}
          )
        end)

        {:ok, updated_agents}

      {:error, {:agent_config, agent_id}, reason, _changes} ->
        {:error, agent_id, reason}
    end
  end

  @doc """
  Updates an agent's admin-managed permission map.
  """
  def update_agent_permissions(%Agent{} = agent, permissions) when is_map(permissions) do
    permissions =
      permissions
      |> Enum.reject(fn {key, _value} -> unused_permission_key?(key) end)
      |> Map.new(fn {key, value} ->
        {to_string(key), permission_truthy?(value)}
      end)

    agent
    |> Ecto.Changeset.change(%{permissions: permissions})
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        Cympho.PubSubGuard.company_broadcast(
          updated.company_id,
          "agents",
          {:agent_updated, updated}
        )

        {:ok, updated}

      error ->
        error
    end
  end

  def update_agent_permissions(%Agent{} = _agent, _permissions),
    do: {:error, :invalid_permissions}

  defp unused_permission_key?(key), do: String.starts_with?(to_string(key), "_unused_")

  defp permission_truthy?(value) when value in [true, "true", "on", "1", 1], do: true

  defp permission_truthy?(values) when is_list(values),
    do: Enum.any?(values, &permission_truthy?/1)

  defp permission_truthy?(_), do: false

  def do_update_agent(agent, attrs) do
    agent
    |> Agent.update_changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        Cympho.PubSubGuard.company_broadcast(
          updated.company_id,
          "agents",
          {:agent_updated, updated}
        )

        {:ok, updated}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Updates an agent by ID, returns {:ok, agent} or {:error, reason}.
  """
  def update_agent_by_id(agent_id, attrs) when is_binary(agent_id) do
    case get_agent(agent_id) do
      {:ok, agent} -> update_agent(agent, attrs)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Deletes an agent.
  """
  def delete_agent(%Agent{} = agent) do
    case Repo.delete(agent) do
      {:ok, _} ->
        # Terminate the per-agent heartbeat GenServer so it doesn't run with
        # stale state pointing at a now-missing DB row.
        _ = Cympho.AgentHeartbeat.stop_for_agent(agent.id)

        Cympho.PubSubGuard.company_broadcast(
          agent.company_id,
          "agents",
          {:agent_deleted, agent.id}
        )

        {:ok, agent}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Returns a changeset for creating or updating an agent.
  """
  def change_agent(%Agent{} = agent, attrs \\ %{}) do
    Agent.changeset(agent, attrs)
  end

  @doc """
  Subscribes to agent updates.
  """
  def subscribe(company_id) when is_binary(company_id) and company_id != "" do
    Phoenix.PubSub.subscribe(Cympho.PubSub, "company:#{company_id}:agents")
  end

  def subscribe(_company_id), do: :ok

  @doc """
  Gets an idle agent by role, or nil if none available.
  """
  def get_idle_agent_by_role(role) do
    Agent
    |> where(role: ^role, status: :idle)
    |> where_active_governance()
    |> first()
    |> Repo.one()
  end

  @doc """
  Gets an idle agent by role within a company, or nil if none available.
  """
  def get_idle_agent_by_role(role, company_id) when is_binary(company_id) do
    Agent
    |> where(role: ^role, status: :idle, company_id: ^company_id)
    |> where_active_governance()
    |> first()
    |> Repo.one()
  end

  @doc """
  Returns agents eligible for dispatch: matching role, idle (or recovered from
  transient `:error`), and not at max_concurrent_jobs capacity.

  Transient `:error` agents are self-healed to `:idle` here so they remain
  eligible under the dispatcher path (AgentHeartbeat skips recovery when
  `delegate_to_dispatcher` is true).
  """
  @spec list_eligible_agents(:ceo | :cto | :engineer) :: [Agent.t()]
  def list_eligible_agents(role) when is_atom(role) do
    Agent
    |> where([a], a.role == ^role and a.status in [:idle, :error])
    |> where_active_governance()
    |> exclude_temporary()
    |> Repo.all()
    |> Enum.flat_map(&eligible_after_error_recovery/1)
  end

  def list_eligible_agents(role, company_id) when is_atom(role) do
    Agent
    |> where([a], a.role == ^role and a.company_id == ^company_id and a.status in [:idle, :error])
    |> where_active_governance()
    |> exclude_temporary()
    |> Repo.all()
    |> Enum.flat_map(&eligible_after_error_recovery/1)
  end

  defp eligible_after_error_recovery(%Agent{} = agent) do
    case recover_error_status(agent) do
      {:ok, %{status: :idle} = recovered} ->
        if is_agent_at_capacity?(recovered), do: [], else: [recovered]

      _ ->
        []
    end
  end

  defp where_active_governance(query) do
    where(query, [a], a.governance_status not in ["paused", "terminated", "pending_approval"])
  end

  @doc """
  Counts the number of :in_progress issues assigned to an agent.
  """
  @spec count_active_assignments(String.t()) :: non_neg_integer()
  def count_active_assignments(agent_id) when is_binary(agent_id) do
    Repo.one(
      from(i in Issue,
        where: i.assignee_id == ^agent_id and i.status == :in_progress,
        select: count(i.id)
      )
    ) || 0
  end

  @doc """
  Returns `%{agent_id => count}` of `:in_progress` assignments for every agent
  in the company that has at least one, computed in a single grouped query so
  prompt building doesn't issue one count per agent (N+1).
  """
  @spec count_active_assignments_by_company(String.t()) :: %{String.t() => non_neg_integer()}
  def count_active_assignments_by_company(company_id) when is_binary(company_id) do
    from(i in Issue,
      where:
        i.company_id == ^company_id and i.status == :in_progress and
          not is_nil(i.assignee_id),
      group_by: i.assignee_id,
      select: {i.assignee_id, count(i.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Counts the number of running jobs for an agent.
  """
  @spec count_running_jobs(String.t()) :: non_neg_integer()
  def count_running_jobs(agent_id) when is_binary(agent_id) do
    Repo.one(
      from(i in Issue,
        where: i.assignee_id == ^agent_id and i.status == :in_progress,
        select: count(i.id)
      )
    ) || 0
  end

  @doc """
  Returns true if the agent is at or above their max_concurrent_jobs limit.
  """
  @spec is_agent_at_capacity?(String.t() | Agent.t()) :: boolean()
  def is_agent_at_capacity?(%Agent{} = agent) do
    running = count_running_jobs(agent.id)
    running >= agent.max_concurrent_jobs
  end

  def is_agent_at_capacity?(agent_id) when is_binary(agent_id) do
    case get_agent(agent_id) do
      {:ok, agent} ->
        running = count_running_jobs(agent_id)
        running >= agent.max_concurrent_jobs

      {:error, _} ->
        true
    end
  end

  @doc """
  Gets an agent by its url_key field, returns {:ok, agent} or {:error, :not_found}.
  """
  def get_agent_by_url_key(url_key) when is_binary(url_key) do
    Repo.one(from a in Agent, where: a.url_key == ^url_key)
    |> case do
      nil -> {:error, :not_found}
      agent -> {:ok, agent}
    end
  end

  @doc """
  Role hierarchy rank: higher rank = more authority.
  Delivery roles sit below CTO/CEO and cannot perform governance actions.
  """
  @spec role_rank(atom()) :: non_neg_integer()
  def role_rank(:product_manager), do: 2
  def role_rank(:engineer), do: 3
  def role_rank(:release_engineer), do: 3
  def role_rank(:qa_engineer), do: 3
  def role_rank(:cto), do: 4
  def role_rank(:ceo), do: 5

  def role_rank(role) when role in [:designer, :researcher, :marketer, :content_strategist],
    do: 1

  def role_rank(role) when role in [:sales_development, :customer_support], do: 1
  def role_rank(_), do: 0

  @doc """
  Returns true if parent_agent can spawn an agent with child_role.
  Parent must have role_rank >= child_rank (allows peer spawning for redundancy).
  """
  @spec spawn_authorized?(Agent.t(), atom()) :: boolean()
  def spawn_authorized?(%Agent{} = parent_agent, child_role) do
    role_rank(parent_agent.role) >= role_rank(child_role)
  end

  @doc """
  Returns the list of roles that the given agent is authorized to spawn.
  """
  @spec spawnable_roles(Agent.t()) :: [atom()]
  def spawnable_roles(%Agent{} = parent_agent) do
    parent_rank = role_rank(parent_agent.role)

    Agent.role_options()
    |> Enum.filter(fn role -> role_rank(role) <= parent_rank end)
  end

  @doc """
  Spawns a new agent: creates the agent record and starts its heartbeat process.
  If governance requires approval for agent_hire, creates a BoardApproval instead
  and returns `{:error, :pending_board_approval, approval_id}`.
  Returns {:ok, agent} or {:error, reason}.
  """
  @spec spawn_agent(map(), String.t()) ::
          {:ok, Agent.t()}
          | {:error, Ecto.Changeset.t() | atom()}
          | {:error, :pending_board_approval, String.t()}
  def spawn_agent(attrs \\ %{}, parent_agent_id) when is_binary(parent_agent_id) do
    with {:ok, parent_agent} <- get_agent(parent_agent_id),
         {:ok, child_attrs} <- validate_spawn(parent_agent, attrs),
         :ok <- maybe_require_spawn_hire_approval(parent_agent, child_attrs) do
      child_attrs_with_creator = Map.put(child_attrs, :created_by_agent_id, parent_agent_id)
      execute_spawn(child_attrs_with_creator)
    end
  end

  defp validate_spawn(%Agent{} = parent_agent, attrs) do
    case attrs do
      %{role: child_role} when is_atom(child_role) ->
        if spawn_authorized?(parent_agent, child_role) do
          {:ok, attrs}
        else
          {:error, :unauthorized_spawn}
        end

      _ ->
        {:error, :missing_role}
    end
  end

  defp execute_spawn(attrs) do
    case do_create_agent(attrs) do
      {:ok, agent} ->
        case Cympho.AgentHeartbeat.start_for_agent(agent.id) do
          {:ok, _pid} ->
            {:ok, agent}

          {:error, reason} ->
            Repo.delete(agent)
            {:error, reason}
        end

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Executes a pending agent hire after board approval.
  Called by BoardApprovalActionExecutor.

  Idempotent: if an agent already exists with the given board_approval_id,
  returns {:error, :already_executed} instead of creating a duplicate.
  """
  def execute_approved_hire(board_approval_id, proposal_data) do
    # Idempotency check: ensure we don't create duplicate agents
    case Repo.get_by(Agent, board_approval_id: board_approval_id) do
      nil ->
        attrs = proposal_data["attrs"] || %{}
        parent_agent_id = proposal_data["parent_agent_id"]

        # Proposal data comes from JSON so keys are strings; keep them strings
        # to avoid Ecto.CastError on a mixed-key map.
        child_attrs =
          if parent_agent_id do
            attrs
            |> Map.put("created_by_agent_id", parent_agent_id)
            |> Map.put("board_approval_id", board_approval_id)
          else
            Map.put(attrs, "board_approval_id", board_approval_id)
          end

        execute_spawn(child_attrs)

      %Agent{} = _existing_agent ->
        # Agent already created for this approval
        {:error, :already_executed}
    end
  end

  @doc """
  Applies a role change directly, bypassing governance checks.
  Called by BoardApprovalActionExecutor when an approval is granted.

  Idempotent: if the agent is already at the target role, returns
  {:error, :already_executed} instead of performing a no-op update.
  """
  def apply_role_change(agent_id, new_role) when is_binary(agent_id) do
    with {:ok, agent} <- get_agent(agent_id) do
      if agent.role == new_role do
        {:error, :already_executed}
      else
        do_update_agent(agent, %{role: new_role})
      end
    end
  end

  # Governance check helpers

  defp maybe_require_hire_approval(attrs) do
    company_id = get_company_id(attrs)

    if company_id && BoardApprovals.governance_required?(company_id, "agent_hire") do
      create_hire_approval(company_id, nil, attrs)
    else
      :ok
    end
  end

  defp maybe_require_spawn_hire_approval(%Agent{company_id: nil}, _attrs), do: :ok

  defp maybe_require_spawn_hire_approval(%Agent{} = parent_agent, attrs) do
    if BoardApprovals.governance_required?(parent_agent.company_id, "agent_hire") do
      create_hire_approval(parent_agent.company_id, parent_agent.id, attrs)
    else
      :ok
    end
  end

  defp create_hire_approval(company_id, requester_agent_id, attrs) do
    role = attrs[:role] || attrs["role"]
    name = attrs[:name] || attrs["name"] || "Unnamed Agent"

    approval_attrs = %{
      title: "Agent Hire: #{name} (#{role})",
      description: "Request to hire new agent '#{name}' with role '#{role}'.",
      category: "agent_hire",
      company_id: company_id,
      proposal_data: %{
        "attrs" => stringify_map_keys(attrs),
        "parent_agent_id" => requester_agent_id
      },
      review_deadline: default_review_deadline()
    }

    {approval_attrs, actor} =
      if requester_agent_id do
        {Map.put(approval_attrs, :requested_by_agent_id, requester_agent_id),
         %Agent{id: requester_agent_id}}
      else
        {approval_attrs, {"system", company_id}}
      end

    case BoardApprovals.create_board_approval(approval_attrs, actor) do
      {:ok, approval} -> {:error, :pending_board_approval, approval.id}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp maybe_require_role_change_approval(%Agent{} = agent, attrs) do
    new_role = extract_role(attrs)

    if new_role && new_role != agent.role && agent.company_id &&
         BoardApprovals.governance_required?(agent.company_id, "agent_promotion") do
      create_role_change_approval(agent, new_role)
    else
      :ok
    end
  end

  defp create_role_change_approval(%Agent{} = agent, new_role) do
    approval_attrs = %{
      title: "Agent Role Change: #{agent.name} (#{agent.role} → #{new_role})",
      description:
        "Request to change agent '#{agent.name}' role from '#{agent.role}' to '#{new_role}'.",
      category: "agent_promotion",
      company_id: agent.company_id,
      requested_by_agent_id: agent.id,
      proposal_data: %{
        "agent_id" => agent.id,
        "current_role" => to_string(agent.role),
        "new_role" => to_string(new_role)
      },
      review_deadline: default_review_deadline()
    }

    case BoardApprovals.create_board_approval(approval_attrs, agent) do
      {:ok, approval} -> {:error, :pending_board_approval, approval.id}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp extract_role(attrs) when is_map(attrs) do
    case attrs[:role] || attrs["role"] do
      nil -> nil
      role when is_atom(role) -> role
      role when is_binary(role) -> String.to_existing_atom(role)
    end
  end

  defp get_company_id(attrs) when is_map(attrs) do
    attrs[:company_id] || attrs["company_id"]
  end

  defp default_review_deadline do
    DateTime.add(DateTime.utc_now(), 7 * 24 * 3600, :second)
  end

  defp stringify_map_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  @doc """
  Returns the inbox for an agent: issues assigned to them, sorted by priority (high first)
  then by insertion date (oldest first). Returns compact maps with id, title, status, priority.
  """
  def list_agent_inbox(agent_id) when is_binary(agent_id) do
    from(i in Issue,
      where:
        i.assignee_id == ^agent_id and i.status in [:todo, :in_progress, :in_review, :blocked],
      select: %{
        id: i.id,
        title: i.title,
        status: i.status,
        priority: i.priority,
        assignee_id: i.assignee_id
      },
      order_by: [
        fragment(
          "CASE ? WHEN 'high' THEN 0 WHEN 'medium' THEN 1 WHEN 'low' THEN 2 ELSE 3 END",
          i.priority
        ),
        asc: i.inserted_at
      ]
    )
    |> Repo.all()
  end

  @doc """
  Stamps `last_heartbeat_at` to now without changing status.

  Used by heartbeat ticks, orchestrator session end, and dispatcher bind so the
  agent roster reflects real runs — not only PATCH `/api/agents/:id/status`.
  """
  @spec touch_heartbeat(Agent.t() | String.t()) :: {:ok, Agent.t()} | {:error, term()}
  def touch_heartbeat(%Agent{} = agent) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    agent
    |> Ecto.Changeset.change(%{last_heartbeat_at: now})
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        broadcast_agent_updated(updated)
        {:ok, updated}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def touch_heartbeat(agent_id) when is_binary(agent_id) do
    case get_agent(agent_id) do
      {:ok, agent} -> touch_heartbeat(agent)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Recovers a transient `:error` agent to `:idle` and stamps `last_heartbeat_at`.

  Operators/circuit breakers park agents as `:paused` or `:terminated` — those
  are deliberately not auto-recovered. Used by AgentHeartbeat and Dispatcher
  so `:error` does not stick forever under the dispatcher-delegation path.
  """
  @spec recover_error_status(Agent.t()) :: {:ok, Agent.t()} | {:error, term()}
  def recover_error_status(%Agent{status: :error} = agent) do
    update_agent_status(agent, %{status: :idle})
  end

  def recover_error_status(%Agent{} = agent), do: {:ok, agent}

  @doc """
  Updates an agent's own status and last_heartbeat_at.
  Uses the restricted status_changeset that only allows status and last_heartbeat_at.
  """
  def update_agent_status(%Agent{} = agent, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # Normalize to string keys so atom-keyed callers (`%{status: :idle}`) do
    # not mix with the stamped last_heartbeat_at and trip Ecto.CastError.
    normalized =
      attrs
      |> Map.new(fn
        {key, value} when is_atom(key) -> {Atom.to_string(key), value}
        {key, value} when is_binary(key) -> {key, value}
      end)
      |> Map.put("last_heartbeat_at", now)

    agent
    |> Agent.status_changeset(normalized)
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        # Fail-closed tenant PubSub (never company::agents).
        Cympho.PubSubGuard.company_broadcast(
          updated.company_id,
          "agents",
          {:agent_updated, updated}
        )

        {:ok, updated}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  # Fail-closed: never form company::agents topics from a nil/blank company_id.
  defp broadcast_agent_updated(%Agent{company_id: company_id} = agent) do
    Cympho.PubSubGuard.company_broadcast(company_id, "agents", {:agent_updated, agent})
  end

  @doc """
  Returns a map with counts of agents by status.
  """
  @spec count_by_status() :: %{
          idle: non_neg_integer(),
          running: non_neg_integer(),
          error: non_neg_integer(),
          sleeping: non_neg_integer(),
          offline: non_neg_integer()
        }
  def count_by_status do
    Agent
    |> exclude_temporary()
    |> group_by([a], a.status)
    |> select([a], {a.status, count(a.id)})
    |> Repo.all()
    |> Enum.into(default_status_counts())
  end

  def count_by_status(company_id) do
    Agent
    |> where(company_id: ^company_id)
    |> exclude_temporary()
    |> group_by([a], a.status)
    |> select([a], {a.status, count(a.id)})
    |> Repo.all()
    |> Enum.into(default_status_counts())
  end

  defp default_status_counts do
    %{
      idle: 0,
      running: 0,
      error: 0,
      sleeping: 0,
      offline: 0,
      active: 0,
      paused: 0,
      pending_approval: 0,
      terminated: 0
    }
  end

  @doc """
  Returns session progress for a running agent.
  Gets current issue, turn count, and elapsed time from AgentHeartbeat and Orchestrator.
  """
  @spec get_session_progress(String.t()) :: {:ok, map()} | {:error, :not_running}
  def get_session_progress(agent_id) when is_binary(agent_id) do
    case Cympho.AgentHeartbeat.status(agent_id) do
      {:ok, :running} ->
        heartbeat_state = get_heartbeat_state(agent_id)
        issue_id = heartbeat_state[:current_issue_id]

        issue_info =
          if issue_id do
            case Repo.get(Issue, issue_id) do
              nil -> nil
              issue -> %{id: issue.id, title: issue.title, identifier: issue.identifier}
            end
          else
            nil
          end

        orchestrator_info = get_orchestrator_info(issue_id)

        {:ok,
         %{
           agent_id: agent_id,
           issue: issue_info,
           turn_count: orchestrator_info[:turn_count] || 0,
           started_at: heartbeat_state[:started_at],
           elapsed_seconds: calculate_elapsed(heartbeat_state[:started_at])
         }}

      {:ok, _} ->
        {:error, :not_running}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_heartbeat_state(agent_id) do
    case Cympho.AgentHeartbeat.whereis(agent_id) do
      {:ok, pid} ->
        try do
          GenServer.call(pid, :get_state, 5000)
        catch
          :exit, _ -> %{status: :unknown}
        end

      :error ->
        %{status: :unknown}
    end
  end

  defp get_orchestrator_info(nil), do: %{turn_count: 0}

  defp get_orchestrator_info(issue_id) do
    case Cympho.Orchestrator.get_session_state(issue_id) do
      nil -> %{turn_count: 0}
      state -> %{turn_count: state[:turn_count]}
    end
  end

  defp calculate_elapsed(nil), do: 0

  defp calculate_elapsed(started_at) do
    DateTime.diff(DateTime.utc_now(), started_at, :second)
  end

  @doc """
  Kills the running session for an agent.
  Stops the Orchestrator session gracefully and resets agent to idle.
  """
  @spec kill_session(String.t()) :: :ok | {:error, :not_running | :not_found}
  def kill_session(agent_id) when is_binary(agent_id) do
    case Cympho.AgentHeartbeat.status(agent_id) do
      {:ok, :running} ->
        heartbeat_state = get_heartbeat_state(agent_id)
        issue_id = heartbeat_state[:current_issue_id]

        if issue_id do
          Cympho.Orchestrator.stop(issue_id, :operator_stop)
        end

        _ = Cympho.AgentHeartbeat.set_idle(agent_id)

        case get_agent(agent_id) do
          {:ok, agent} ->
            update_agent(agent, %{status: :idle})

          {:error, _} ->
            :error
        end

        :ok

      {:ok, _} ->
        {:error, :not_running}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns all agents with their parent and children preloaded.
  """
  def list_agents_with_hierarchy do
    Agent
    |> exclude_temporary()
    |> preload([:parent, :children])
    |> Repo.all()
  end

  @doc """
  Returns the org chart as a tree structure starting from root agents (no parent).
  """
  def get_org_chart do
    roots =
      Agent
      |> where([a], is_nil(a.parent_id))
      |> exclude_temporary()
      |> preload([:children])
      |> Repo.all()

    build_org_tree(roots)
  end

  def get_org_chart(company_id) do
    roots =
      Agent
      |> where([a], a.company_id == ^company_id and is_nil(a.parent_id))
      |> exclude_temporary()
      |> preload([:children])
      |> Repo.all()

    build_org_tree(roots)
  end

  defp build_org_tree(agents) when is_list(agents) do
    Enum.map(agents, &build_org_tree/1)
  end

  defp build_org_tree(%Agent{} = agent) do
    agent_with_children =
      Agent
      |> where([a], a.id == ^agent.id)
      |> preload([:children, children: [:children]])
      |> Repo.one()

    children = Enum.reject(agent_with_children.children || [], &temporary?/1)

    %{
      id: agent_with_children.id,
      name: agent_with_children.name,
      title: agent_with_children.title,
      role: agent_with_children.role,
      status: agent_with_children.status,
      adapter: agent_with_children.adapter,
      children: build_org_tree(children)
    }
  end

  @doc """
  Returns all children of an agent (direct reports).
  """
  def list_children(agent_id) when is_binary(agent_id) do
    Agent
    |> where([a], a.parent_id == ^agent_id)
    |> Repo.all()
  end

  @doc """
  Returns the parent of an agent.
  """
  def get_parent(agent_id) when is_binary(agent_id) do
    case Repo.get(Agent, agent_id) do
      nil -> {:error, :not_found}
      %{parent: nil} -> {:ok, nil}
      %{parent: parent} -> {:ok, parent}
    end
  end

  @doc """
  Returns all ancestors of an agent (parent chain to root).
  """
  def get_ancestors(agent_id) when is_binary(agent_id) do
    case get_agent(agent_id) do
      {:error, _} -> []
      {:ok, agent} -> build_ancestors(agent)
    end
  end

  defp build_ancestors(nil), do: []

  defp build_ancestors(%Agent{parent: nil}), do: []

  defp build_ancestors(%Agent{parent: parent} = _agent) do
    [parent | build_ancestors(parent)]
  end

  @doc """
  Returns all descendants of an agent (all children, grandchildren, etc.).
  """
  def get_descendants(agent_id) when is_binary(agent_id) do
    case get_agent(agent_id) do
      {:error, _} -> []
      {:ok, agent} -> build_descendants(agent)
    end
  end

  defp build_descendants(%Agent{} = agent) do
    children =
      Agent
      |> where([a], a.parent_id == ^agent.id)
      |> Repo.all()

    children ++ Enum.flat_map(children, &build_descendants/1)
  end

  @doc """
  Pauses an agent by setting runtime and governance status to paused.
  """
  def pause_agent(%Agent{} = agent) do
    pause_agent(agent, "Agent paused")
  end

  def pause_agent(agent_id) when is_binary(agent_id) do
    pause_agent(agent_id, "Agent paused")
  end

  def pause_agent(%Agent{} = agent, reason) when is_binary(reason) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    agent
    |> Ecto.Changeset.change(%{
      status: :paused,
      governance_status: "paused",
      governance_reasoning: reason,
      paused_at: now,
      pause_reason: reason
    })
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        _ = Cympho.Issues.RehomePaused.rehome_for_paused_agent(updated, reason: reason)

        Cympho.PubSubGuard.company_broadcast(
          updated.company_id,
          "agents",
          {:agent_paused, updated}
        )

        {:ok, updated}

      error ->
        error
    end
  end

  def pause_agent(agent_id, reason) when is_binary(agent_id) and is_binary(reason) do
    case get_agent(agent_id) do
      {:ok, agent} -> pause_agent(agent, reason)
      error -> error
    end
  end

  @doc """
  Resumes a paused agent by setting status to :idle.
  """
  def resume_agent(%Agent{} = agent) do
    agent
    |> Ecto.Changeset.change(%{
      status: :idle,
      governance_status: "active",
      governance_reasoning: nil,
      paused_at: nil,
      pause_reason: nil,
      paused_by_user_id: nil
    })
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        Cympho.PubSubGuard.company_broadcast(
          updated.company_id,
          "agents",
          {:agent_updated, updated}
        )

        {:ok, updated}

      error ->
        error
    end
  end

  def resume_agent(agent_id) when is_binary(agent_id) do
    case get_agent(agent_id) do
      {:ok, agent} -> resume_agent(agent)
      error -> error
    end
  end

  @doc """
  Terminates an agent by setting status to :terminated.
  """
  def terminate_agent(%Agent{} = agent) do
    case agent.status do
      :running ->
        case kill_session(agent.id) do
          :ok -> update_agent(agent, %{status: :terminated, terminated_at: DateTime.utc_now()})
          error -> error
        end

      _ ->
        update_agent(agent, %{status: :terminated, terminated_at: DateTime.utc_now()})
    end
  end

  def terminate_agent(agent_id) when is_binary(agent_id) do
    case get_agent(agent_id) do
      {:ok, agent} -> terminate_agent(agent)
      error -> error
    end
  end

  @doc """
  Returns all config revisions for an agent, ordered by version (newest first).
  """
  def list_config_revisions(agent_id, opts \\ []) when is_binary(agent_id) do
    query =
      AgentConfigRevision
      |> where(agent_id: ^agent_id)
      |> order_by(desc: :version)

    query =
      case Keyword.get(opts, :limit) do
        limit when is_integer(limit) and limit > 0 -> limit(query, ^limit)
        _ -> query
      end

    Repo.all(query)
  end

  @doc """
  Gets the latest config revision for an agent.
  """
  def get_latest_config_revision(agent_id) when is_binary(agent_id) do
    AgentConfigRevision
    |> where(agent_id: ^agent_id)
    |> order_by(desc: :version)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Creates a new config revision for an agent.
  Automatically increments the version number.
  """
  def create_config_revision(%Agent{} = agent, attrs) when is_map(attrs) do
    studio = Map.get(attrs, :studio) || AgentInstructionStudio.analyze(agent)
    studio_audits_extra = Map.get(attrs, :studio_audits_extra, %{})

    attrs =
      attrs
      |> Map.drop([:studio, :studio_audits_extra])
      |> Map.put_new(:role, atom_to_string(agent.role))
      |> Map.put_new(:adapter, atom_to_string(agent.adapter))
      |> Map.put_new(:instructions, agent.instructions)
      |> Map.put_new(:config, agent.config || %{})
      |> Map.put_new(:runtime_config, agent.runtime_config || %{})
      |> Map.put_new(:studio_score, studio.score)
      |> Map.put_new(:studio_status, atom_to_string(studio.status))
      |> Map.put_new(:studio_audits, studio_revision_payload(studio, studio_audits_extra))
      |> Map.put_new(:source, "manual")

    create_config_revision(agent.id, attrs)
  end

  def create_config_revision(agent_id, attrs) when is_binary(agent_id) do
    latest_version =
      get_latest_version_number(agent_id)

    new_attrs =
      attrs
      |> Map.put(:agent_id, agent_id)
      |> Map.put(:version, latest_version + 1)

    %AgentConfigRevision{}
    |> AgentConfigRevision.changeset(new_attrs)
    |> Repo.insert()
  end

  def create_config_revision(%Agent{} = agent), do: create_config_revision(agent, %{})

  def create_config_revision(agent_id) when is_binary(agent_id),
    do: create_config_revision(agent_id, %{})

  @doc """
  Gets the current version number for an agent's config revisions.
  Returns 0 if no revisions exist.
  """
  def get_latest_version_number(agent_id) when is_binary(agent_id) do
    case get_latest_config_revision(agent_id) do
      nil -> 0
      revision -> revision.version
    end
  end

  @doc """
  Restores an agent to a specific config revision.
  Creates a new revision with the restored content.
  """
  def restore_config_revision(agent_id, revision_id, opts \\ []) do
    case Repo.get(AgentConfigRevision, revision_id) do
      nil ->
        {:error, :not_found}

      %{agent_id: ^agent_id} = revision ->
        case get_agent(agent_id) do
          {:ok, agent} ->
            attrs = restore_config_attrs(revision)

            with {:ok, updated_agent} <- update_agent(agent, attrs),
                 {:ok, _new_revision} <-
                   create_config_revision(
                     updated_agent,
                     restore_revision_attrs(revision, opts)
                   ) do
              {:ok, updated_agent}
            end

          {:error, reason} ->
            {:error, reason}
        end

      _revision ->
        {:error, :not_found}
    end
  end

  @doc """
  Compares two config revisions and returns the differences.
  """
  def compare_config_revisions(revision1_id, revision2_id) do
    revision1 = Repo.get(AgentConfigRevision, revision1_id)
    revision2 = Repo.get(AgentConfigRevision, revision2_id)

    cond do
      is_nil(revision1) or is_nil(revision2) ->
        {:error, :not_found}

      true ->
        %{
          instructions_diff: compare_text(revision1.instructions, revision2.instructions),
          config_diff: compare_maps(revision1.config, revision2.config),
          runtime_config_diff: compare_maps(revision1.runtime_config, revision2.runtime_config),
          score_diff: compare_scores(revision1.studio_score, revision2.studio_score)
        }
    end
  end

  defp compare_text(nil, nil), do: :unchanged
  defp compare_text(text1, text2) when text1 == text2, do: :unchanged
  defp compare_text(nil, _text2), do: :added
  defp compare_text(_text1, nil), do: :removed
  defp compare_text(_text1, _text2), do: :changed

  defp compare_maps(map1, map2) when map1 == map2, do: :unchanged
  defp compare_maps(_map1, _map2), do: :changed

  defp compare_scores(score1, score2) when score1 == score2, do: :unchanged
  defp compare_scores(nil, _score2), do: :added
  defp compare_scores(_score1, nil), do: :removed
  defp compare_scores(score1, score2) when score1 < score2, do: :improved
  defp compare_scores(_score1, _score2), do: :regressed

  defp restore_config_attrs(revision) do
    %{
      instructions: revision.instructions,
      config: revision.config || %{},
      runtime_config: revision.runtime_config || %{}
    }
    |> maybe_put(:role, revision.role)
    |> maybe_put(:adapter, revision.adapter)
  end

  defp restore_revision_attrs(revision, opts) do
    %{
      source: "restore",
      restored_from_revision_id: revision.id
    }
    |> maybe_put(:created_by_user_id, Keyword.get(opts, :created_by_user_id))
    |> maybe_put(:created_by_agent_id, Keyword.get(opts, :created_by_agent_id))
  end

  defp studio_revision_payload(studio, extra) do
    %{
      "audits" =>
        Enum.map(studio.audits, fn audit ->
          %{
            "key" => atom_to_string(audit.key),
            "label" => audit.label,
            "status" => atom_to_string(audit.status),
            "detail" => audit.detail,
            "fix" => audit.fix
          }
        end),
      "scenarios" =>
        Enum.map(studio.scenarios, fn scenario ->
          %{
            "key" => atom_to_string(scenario.key),
            "label" => scenario.label,
            "status" => atom_to_string(scenario.status),
            "detail" => scenario.detail,
            "fix" => scenario.fix
          }
        end)
    }
    |> Map.merge(string_key_map(extra))
  end

  defp string_key_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp string_key_map(_), do: %{}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp atom_to_string(nil), do: nil
  defp atom_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp atom_to_string(value), do: to_string(value)

  @doc """
  Returns statistics for a specific agent including:
  - Direct reports count
  - Total issues assigned
  - Issues completed this week
  - Blocked issues count
  - Budget status (if applicable)
  """
  def get_agent_stats(agent_id) when is_binary(agent_id) do
    case get_agent(agent_id) do
      {:ok, agent} ->
        %{
          direct_reports: count_direct_reports(agent_id),
          total_issues: count_assigned_issues(agent_id),
          completed_this_week: count_completed_this_week(agent_id),
          blocked_count: count_blocked_issues(agent_id),
          budget_status: get_agent_budget_status(agent)
        }

      {:error, _} ->
        nil
    end
  end

  @doc """
  Returns company-wide agent statistics grouped by role and status.
  """
  def get_company_agent_stats(company_id) when is_binary(company_id) do
    agents = list_agents_by_company(company_id)

    %{
      total: length(agents),
      by_role: Enum.group_by(agents, & &1.role) |> Map.new(fn {k, v} -> {k, length(v)} end),
      by_status: Enum.group_by(agents, & &1.status) |> Map.new(fn {k, v} -> {k, length(v)} end),
      idle_ratio: calculate_idle_ratio(agents)
    }
  end

  defp count_direct_reports(agent_id) do
    Agent
    |> where([a], a.parent_id == ^agent_id)
    |> Repo.aggregate(:count)
  end

  defp count_assigned_issues(agent_id) do
    Cympho.Issues.Issue
    |> where([i], i.assignee_id == ^agent_id)
    |> Repo.aggregate(:count)
  end

  defp count_completed_this_week(agent_id) do
    week_start_date = Date.beginning_of_week(DateTime.utc_now() |> DateTime.to_date())
    week_start = DateTime.new!(week_start_date, ~T[00:00:00])

    Cympho.Issues.Issue
    |> where([i], i.assignee_id == ^agent_id)
    |> where([i], i.status == :done)
    |> where([i], not is_nil(i.completed_at))
    |> where([i], i.completed_at >= ^week_start)
    |> Repo.aggregate(:count)
  end

  defp count_blocked_issues(agent_id) do
    Cympho.Issues.Issue
    |> where([i], i.assignee_id == ^agent_id)
    |> where([i], i.status == :blocked)
    |> Repo.aggregate(:count)
  end

  defp get_agent_budget_status(%Agent{budget_monthly_cents: limit})
       when is_nil(limit) or limit == 0,
       do: nil

  defp get_agent_budget_status(%Agent{budget_monthly_cents: limit, spent_monthly_cents: spent}) do
    limit_decimal = Decimal.new(limit)
    spent_decimal = Decimal.new(spent)

    %{
      limit: limit_decimal,
      spent: spent_decimal,
      remaining: Decimal.sub(limit_decimal, spent_decimal),
      percentage:
        if Decimal.gt?(limit_decimal, 0) do
          Decimal.mult(Decimal.div(spent_decimal, limit_decimal), 100)
        else
          Decimal.new(0)
        end
    }
  end

  defp get_agent_budget_status(_), do: nil

  defp exclude_temporary(query) do
    where(
      query,
      [a],
      fragment(
        """
        COALESCE((?->>'temporary')::boolean, false) = false
        AND COALESCE((?->>'one_time')::boolean, false) = false
        AND COALESCE((?->'swarm'->>'temporary')::boolean, false) = false
        AND COALESCE((?->'swarm'->>'one_time')::boolean, false) = false
        """,
        a.config,
        a.config,
        a.runtime_config,
        a.runtime_config
      )
    )
  end

  defp truthy_config?(map, key) when is_map(map) do
    Map.get(map, key) in [true, "true", "1", 1]
  end

  defp truthy_config?(_map, _key), do: false

  defp calculate_idle_ratio(agents) when is_list(agents) do
    total = length(agents)
    idle = Enum.count(agents, &(&1.status == :idle))

    if total > 0 do
      Float.round(idle / total * 100, 1)
    else
      0.0
    end
  end
end
