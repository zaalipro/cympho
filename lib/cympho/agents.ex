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
  Counts the number of running jobs for an agent.
  """
  @spec count_running_jobs(String.t()) :: non_neg_integer()
  def count_running_jobs(agent_id) when is_binary(agent_id) do
    Repo.one(
      from(i in Issue,
        where: i.assignee_id == ^agent_id and i.status == :running,
        select: count(i.id)
      )
    ) || 0
  end

  @doc """
  Returns true if the agent is at or above their max_concurrent_jobs limit.
  """
  @spec is_agent_at_capacity?(String.t()) :: boolean()
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
  Spawns a new agent: creates the agent record and starts its heartbeat process.
  Returns {:ok, agent} or {:error, reason}.
  """
  @spec spawn_agent(map(), String.t()) :: {:ok, Agent.t()} | {:error, Ecto.Changeset.t() | atom()}
  def spawn_agent(attrs \\ %{}, parent_agent_id) when is_binary(parent_agent_id) do
    case create_agent(attrs) do
      {:ok, agent} ->
        case Cympho.AgentHeartbeat.start_for_agent(agent.id) do
          {:ok, _pid} ->
            {:ok, agent}

          {:error, reason} ->
            # Clean up the agent record if heartbeat start fails
            Repo.delete(agent)
            {:error, reason}
        end

      {:error, changeset} ->
        {:error, changeset}
    end
  end
end