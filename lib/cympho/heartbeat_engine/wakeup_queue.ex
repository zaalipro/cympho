defmodule Cympho.HeartbeatEngine.WakeupQueue do
  @moduledoc """
  DB-backed wakeup queue with coalescing.

  Multiple wake events for the same agent/issue pair are coalesced into a single
  wake record. When a new wake arrives for an agent that already has a pending wake,
  the existing record is updated with the latest reason and metadata instead of
  creating a duplicate.
  """

  import Ecto.Query, warn: false
  alias Cympho.Repo
  alias Cympho.Wakes.AgentWake
  require Logger

  @doc """
  Enqueues a wake event, coalescing if a pending wake already exists for this agent/issue pair.

  Returns `{:ok, agent_wake}` with either the new or updated record.
  """
  @spec enqueue(map()) :: {:ok, AgentWake.t()} | {:error, Ecto.Changeset.t()}
  def enqueue(%{agent_id: agent_id, issue_id: issue_id, reason: reason} = attrs) do
    triggered_by_type = Map.get(attrs, :triggered_by_type, "system")
    triggered_by_id = Map.get(attrs, :triggered_by_id)
    metadata = Map.get(attrs, :metadata, %{})

    existing =
      Repo.one(
        from w in AgentWake,
          where:
            w.agent_id == ^agent_id and
              w.issue_id == ^issue_id and
              w.reason == ^reason,
          order_by: [desc: w.inserted_at],
          limit: 1
      )

    case existing do
      nil ->
        %AgentWake{}
        |> AgentWake.changeset(%{
          agent_id: agent_id,
          issue_id: issue_id,
          reason: reason,
          triggered_by_type: triggered_by_type,
          triggered_by_id: triggered_by_id,
          metadata: metadata
        })
        |> Repo.insert()

      wake ->
        Logger.debug("WakeupQueue: coalescing wake for agent #{agent_id}, issue #{issue_id}")

        wake
        |> AgentWake.changeset(%{
          triggered_by_type: triggered_by_type,
          triggered_by_id: triggered_by_id,
          metadata: merge_metadata(wake.metadata, metadata)
        })
        |> Repo.update()
    end
  end

  @doc """
  Dequeues the next wake event for a given agent.
  Returns the most recent pending wake for the agent, or nil.
  """
  @spec dequeue(String.t()) :: {:ok, AgentWake.t()} | {:error, :empty}
  def dequeue(agent_id) do
    wake =
      Repo.one(
        from w in AgentWake,
          where: w.agent_id == ^agent_id,
          order_by: [desc: w.inserted_at],
          limit: 1
      )

    case wake do
      nil -> {:error, :empty}
      wake -> {:ok, wake}
    end
  end

  @doc """
  Returns the count of pending wakes for an agent.
  """
  @spec pending_count(String.t()) :: non_neg_integer()
  def pending_count(agent_id) do
    Repo.one(
      from w in AgentWake,
        where: w.agent_id == ^agent_id,
        select: count(w.id)
    )
  end

  @doc """
  Lists pending wakes for an agent, ordered by most recent first.
  """
  @spec list_pending(String.t(), keyword()) :: [AgentWake.t()]
  def list_pending(agent_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    AgentWake
    |> where(agent_id: ^agent_id)
    |> order_by([w], desc: w.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  defp merge_metadata(existing, new) do
    Map.merge(existing || %{}, new || %{})
  end
end
