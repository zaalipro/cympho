defmodule Cympho.Agents do
  @moduledoc """
  The Agents context manages agent entities and their lifecycle.
  """

  import Ecto.Query, warn: false
  alias Cympho.Repo
  alias Cympho.Agents.Agent
  alias Cympho.Issues.Issue

  @doc """
  Returns the list of all agents.
  """
  def list_agents do
    Repo.all(Agent)
  end

  @doc """
  Returns agents with the specified role.
  """
  def list_agents_by_role(role) when is_atom(role) do
    Agent
    |> where(role: ^role)
    |> Repo.all()
  end

  @doc """
  Returns agents with the specified status.
  """
  def list_agents_by_status(status) when is_atom(status) do
    Agent
    |> where(status: ^status)
    |> Repo.all()
  end

  @doc """
  Gets a single agent by id.
  """
  def get_agent!(id), do: Repo.get!(Agent, id)

  @doc """
  Gets a single agent by id, returns {:ok, agent} or {:error, :not_found}.
  """
  def get_agent(id) do
    case Repo.get(Agent, id) do
      nil -> {:error, :not_found}
      agent -> {:ok, agent}
    end
  end

  @doc """
  Creates an agent.
  """
  def create_agent(attrs \\ %{}) do
    %Agent{}
    |> Agent.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, agent} ->
        Phoenix.PubSub.broadcast(Cympho.PubSub, "agents", {:agent_created, agent})
        {:ok, agent}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Updates an agent.
  """
  def update_agent(%Agent{} = agent, attrs) do
    agent
    |> Agent.changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        Phoenix.PubSub.broadcast(Cympho.PubSub, "agents", {:agent_updated, updated})
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
    Repo.delete(agent)
    |> case do
      {:ok, _} ->
        Phoenix.PubSub.broadcast(Cympho.PubSub, "agents", {:agent_deleted, agent.id})
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
  def subscribe do
    Phoenix.PubSub.subscribe(Cympho.PubSub, "agents")
  end

  @doc """
  Gets an idle agent by role, or nil if none available.
  """
  def get_idle_agent_by_role(role) do
    Agent
    |> where(role: ^role, status: :idle)
    |> first()
    |> Repo.one()
  end

  @doc """
  Returns agents eligible for dispatch: matching role, not in :error status,
  and not at max_concurrent_jobs capacity.
  """
  @spec list_eligible_agents(:ceo | :cto | :engineer) :: [Agent.t()]
  def list_eligible_agents(role) when is_atom(role) do
    Agent
    |> where(role: ^role, status: :idle)
    |> Repo.all()
    |> Enum.reject(&is_agent_at_capacity?/1)
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
  Order: designer(1) < product_manager(2) < engineer(3) < cto(4) < ceo(5)
  """
  @spec role_rank(:designer | :product_manager | :engineer | :cto | :ceo) :: non_neg_integer()
  def role_rank(:designer), do: 1
  def role_rank(:product_manager), do: 2
  def role_rank(:engineer), do: 3
  def role_rank(:cto), do: 4
  def role_rank(:ceo), do: 5

  @doc """
  Returns true if parent_agent can spawn an agent with child_role.
  Parent must have role_rank >= child_rank (allows peer spawning for redundancy).
  """
  @spec spawn_authorized?(Agent.t(), :designer | :product_manager | :engineer | :cto | :ceo) ::
          boolean()
  def spawn_authorized?(%Agent{} = parent_agent, child_role) do
    role_rank(parent_agent.role) >= role_rank(child_role)
  end

  @doc """
  Returns the list of roles that the given agent is authorized to spawn.
  """
  @spec spawnable_roles(Agent.t()) :: [
          :designer | :product_manager | :engineer | :cto | :ceo,
          ...
        ]
  def spawnable_roles(%Agent{} = parent_agent) do
    parent_rank = role_rank(parent_agent.role)

    [:designer, :product_manager, :engineer, :cto, :ceo]
    |> Enum.filter(fn role -> role_rank(role) <= parent_rank end)
  end

  @doc """
  Spawns a new agent: creates the agent record and starts its heartbeat process.
  Returns {:ok, agent} or {:error, reason}.
  """
  @spec spawn_agent(map(), String.t()) :: {:ok, Agent.t()} | {:error, Ecto.Changeset.t() | atom()}
  def spawn_agent(attrs \\ %{}, parent_agent_id) when is_binary(parent_agent_id) do
    with {:ok, parent_agent} <- get_agent(parent_agent_id),
         {:ok, child_attrs} <- validate_spawn(parent_agent, attrs) do
      child_attrs_with_creator = Map.put(child_attrs, :created_by_agent_id, parent_agent_id)
      do_spawn_agent(child_attrs_with_creator)
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

  defp do_spawn_agent(attrs) do
    case create_agent(attrs) do
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
  Updates an agent's own status and last_heartbeat_at.
  Uses the restricted status_changeset that only allows status and last_heartbeat_at.
  """
  def update_agent_status(%Agent{} = agent, attrs) do
    agent
    |> Agent.status_changeset(Map.put(attrs, "last_heartbeat_at", DateTime.utc_now()))
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        Phoenix.PubSub.broadcast(Cympho.PubSub, "agents", {:agent_updated, updated})
        {:ok, updated}

      {:error, changeset} ->
        {:error, changeset}
    end
  end
end

  @doc """
  Returns a map with counts of agents by status.
  """
  @spec count_by_status() :: %{idle: non_neg_integer(), running: non_neg_integer(), error: non_neg_integer(), sleeping: non_neg_integer(), offline: non_neg_integer()}
  def count_by_status do
    from(a in Agent,
      group_by: a.status,
      select: {a.status, count(a.id)}
    )
    |> Repo.all()
    |> Enum.into(%{idle: 0, running: 0, error: 0, sleeping: 0, offline: 0})
  end

  @doc """
  Returns session progress for a running agent.
  """
  @spec get_session_progress(String.t()) :: {:ok, map()} | {:error, :not_running}
  def get_session_progress(agent_id) when is_binary(agent_id) do
    case Cympho.AgentHeartbeat.status(agent_id) do
      {:ok, :running} ->
        heartbeat_state = get_heartbeat_state(agent_id)
        issue_id = heartbeat_state[:current_issue_id]
        issue_info = if issue_id do
          case Repo.get(Issue, issue_id) do
            nil -> nil
            issue -> %{id: issue.id, title: issue.title, identifier: issue.identifier}
          end
        else
          nil
        end
        orchestrator_info = get_orchestrator_info(issue_id)
        {:ok, %{
          agent_id: agent_id,
          issue: issue_info,
          turn_count: orchestrator_info[:turn_count] || 0,
          started_at: heartbeat_state[:started_at],
          elapsed_seconds: calculate_elapsed(heartbeat_state[:started_at])
        }}
      {:ok, _} -> {:error, :not_running}
      {:error, reason} -> {:error, reason}
    end
  end

  defp get_heartbeat_state(agent_id) do
    case Cympho.AgentHeartbeat.Registry.lookup(agent_id) do
      {:ok, pid} -> try do GenServer.call(pid, :get_state, 5000) catch :exit, _ -> %{status: :unknown} end
      :error -> %{status: :unknown}
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
  defp calculate_elapsed(started_at), do: DateTime.diff(DateTime.utc_now(), started_at, :second)

  @doc """
  Kills the running session for an agent.
  """
  @spec kill_session(String.t()) :: :ok | {:error, :not_running | :not_found}
  def kill_session(agent_id) when is_binary(agent_id) do
    case Cympho.AgentHeartbeat.status(agent_id) do
      {:ok, :running} ->
        heartbeat_state = get_heartbeat_state(agent_id)
        issue_id = heartbeat_state[:current_issue_id]
        if issue_id, do: Cympho.Orchestrator.stop(issue_id)
        _ = Cympho.AgentHeartbeat.set_idle(agent_id)
        case get_agent(agent_id) do
          {:ok, agent} -> update_agent(agent, %{status: :idle})
          {:error, _} -> :error
        end
        :ok
      {:ok, _} -> {:error, :not_running}
      {:error, reason} -> {:error, reason}
    end
