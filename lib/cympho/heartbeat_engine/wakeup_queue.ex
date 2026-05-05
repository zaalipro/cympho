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

  # Default cap on pending wakes per agent. Without this a runaway agent
  # (or a noisy upstream) can insert wakes faster than the agent consumes
  # them and grow the `agent_wakes` table without bound. Reads/writes scale
  # O(pending) within the dequeue path, so the cap is also a latency floor.
  # Read at runtime so tests can adjust it via Application.put_env.
  @default_max_pending_wakes_per_agent 100

  defp max_pending_wakes_per_agent do
    Application.get_env(:cympho, :wakeup_queue, [])
    |> Keyword.get(:max_pending_per_agent, @default_max_pending_wakes_per_agent)
  end

  @doc """
  Enqueues a wake event, coalescing if a pending wake already exists for this agent/issue pair.

  Returns `{:ok, agent_wake}` with either the new or updated record. When the
  per-agent pending cap is exceeded and there's no existing wake to coalesce
  with, returns `{:error, :wakeup_queue_full}`.
  """
  @spec enqueue(map()) ::
          {:ok, AgentWake.t()}
          | {:error, Ecto.Changeset.t() | :wakeup_queue_full}
  def enqueue(%{agent_id: agent_id, issue_id: issue_id, reason: reason} = attrs) do
    triggered_by_type = Map.get(attrs, :triggered_by_type, "system")
    triggered_by_id = Map.get(attrs, :triggered_by_id)
    metadata = Map.get(attrs, :metadata, %{})

    existing =
      AgentWake
      |> where([w], w.agent_id == ^agent_id and w.reason == ^reason and w.status == "pending")
      |> where_issue(issue_id)
      |> order_by([w], desc: w.inserted_at)
      |> limit(1)
      |> Repo.one()

    case existing do
      nil ->
        cap = max_pending_wakes_per_agent()

        if pending_count(agent_id) >= cap do
          Logger.warning(
            "WakeupQueue: rejecting wake for agent #{agent_id}, queue full (cap=#{cap})"
          )

          {:error, :wakeup_queue_full}
        else
          %AgentWake{}
          |> AgentWake.changeset(%{
            agent_id: agent_id,
            issue_id: issue_id,
            reason: reason,
            status: "pending",
            triggered_by_type: triggered_by_type,
            triggered_by_id: triggered_by_id,
            metadata: metadata
          })
          |> Repo.insert()
        end

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
  Returns the oldest pending wake for the agent, or nil.
  """
  @spec dequeue(String.t()) :: {:ok, AgentWake.t()} | {:error, :empty}
  def dequeue(agent_id) do
    wake =
      Repo.one(
        from w in AgentWake,
          where: w.agent_id == ^agent_id and w.status == "pending",
          order_by: [asc: w.inserted_at, asc: w.id],
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
        where: w.agent_id == ^agent_id and w.status == "pending",
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
    |> where([w], w.agent_id == ^agent_id and w.status == "pending")
    |> order_by([w], desc: w.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Marks a wake as consumed after an agent has started processing it.
  """
  @spec mark_consumed(AgentWake.t()) :: {:ok, AgentWake.t()} | {:error, Ecto.Changeset.t()}
  def mark_consumed(%AgentWake{} = wake) do
    wake
    |> AgentWake.changeset(%{status: "consumed", consumed_at: DateTime.utc_now()})
    |> Repo.update()
  end

  @doc """
  Marks all pending wakes for an agent/issue pair as consumed.
  """
  @spec consume_for(String.t(), String.t()) :: :ok
  def consume_for(agent_id, issue_id) do
    now = DateTime.utc_now()

    AgentWake
    |> where([w], w.agent_id == ^agent_id and w.status == "pending")
    |> where_issue(issue_id)
    |> Repo.update_all(set: [status: "consumed", consumed_at: now])

    :ok
  end

  defp where_issue(query, nil), do: where(query, [w], is_nil(w.issue_id))
  defp where_issue(query, issue_id), do: where(query, [w], w.issue_id == ^issue_id)

  defp merge_metadata(existing, new) do
    Map.merge(existing || %{}, new || %{})
  end
end
