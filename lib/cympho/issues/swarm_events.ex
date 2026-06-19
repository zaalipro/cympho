defmodule Cympho.Issues.SwarmEvents do
  @moduledoc """
  Durable, parent-scoped event stream for swarm orchestration.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Cympho.Issues.Issue
  alias Cympho.Issues.SwarmEvent
  alias Cympho.PubSubGuard
  alias Cympho.Repo

  @default_limit 80
  @event_order %{
    "launch_started" => 10,
    "temporary_agents_created" => 20,
    "worker_issues_created" => 30,
    "cto_issue_created" => 40,
    "dependencies_linked" => 50,
    "cto_blocked_on_workers" => 60,
    "parent_blocked_on_cto" => 70,
    "worker_wakes_enqueued" => 80,
    "worker_wakes_attention_required" => 80,
    "launch_ready" => 90,
    "worker_completed" => 120,
    "worker_blocked" => 130,
    "cto_synthesis_completed" => 200,
    "cto_requested_changes" => 210,
    "cto_synthesis_blocked" => 220,
    "ceo_handoff_created" => 300,
    "ceo_requested_changes" => 310,
    "ceo_delivery_completed" => 320,
    "parent_blocked" => 330
  }

  def subscribe(company_id) when is_binary(company_id) do
    Phoenix.PubSub.subscribe(Cympho.PubSub, topic(company_id))
  end

  def subscribe(_company_id), do: :ok

  def list_for_issue(%Issue{} = issue, opts \\ []) do
    case parent_issue_id(issue) do
      nil -> []
      parent_issue_id -> list_for_parent(parent_issue_id, opts)
    end
  end

  def list_for_parent(parent_issue_id, opts \\ [])

  def list_for_parent(parent_issue_id, opts) when is_binary(parent_issue_id) do
    limit = Keyword.get(opts, :limit, @default_limit)

    SwarmEvent
    |> where(parent_issue_id: ^parent_issue_id)
    |> order_by([e], desc: e.occurred_at, desc: e.inserted_at)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.sort_by(&event_sort_key/1)
  end

  def list_for_parent(_parent_issue_id, _opts), do: []

  def record(%Issue{} = issue, attrs) when is_map(attrs) do
    attrs =
      attrs
      |> Map.new()
      |> Map.put_new(:company_id, issue.company_id)
      |> Map.put_new(:parent_issue_id, parent_issue_id(issue))
      |> Map.put_new(:issue_id, issue.id)
      |> Map.update(:metadata, %{}, &normalize_metadata/1)

    safe_insert(attrs)
  end

  def record(attrs) when is_map(attrs) do
    attrs =
      attrs
      |> Map.new()
      |> Map.update(:metadata, %{}, &normalize_metadata/1)

    safe_insert(attrs)
  end

  def record(_attrs), do: :ok

  def parent_issue_id(%Issue{} = issue) do
    swarm = swarm_state(issue)

    cond do
      is_binary(swarm_value(swarm, "parent_issue_id")) ->
        swarm_value(swarm, "parent_issue_id")

      issue.origin_type in ["swarm_worker", "swarm_cto_review"] and is_binary(issue.parent_id) ->
        issue.parent_id

      truthy?(swarm_value(swarm, "enabled")) ->
        issue.id

      true ->
        issue.id
    end
  end

  def parent_issue_id(_issue), do: nil

  def swarm_role(%Issue{} = issue) do
    swarm = swarm_state(issue)

    cond do
      issue.origin_type == "swarm_worker" -> "worker"
      issue.origin_type == "swarm_cto_review" -> "cto_synthesis"
      is_binary(swarm_value(swarm, "role")) -> swarm_value(swarm, "role")
      truthy?(swarm_value(swarm, "enabled")) -> "parent"
      true -> nil
    end
  end

  def swarm_role(_issue), do: nil

  defp safe_insert(attrs) do
    case %SwarmEvent{} |> SwarmEvent.changeset(attrs) |> Repo.insert() do
      {:ok, event} ->
        _ = PubSubGuard.broadcast(topic(event.company_id), {:swarm_event_created, event})
        :ok

      {:error, changeset} ->
        Logger.warning("[SwarmEvents] failed to record event: #{inspect(changeset.errors)}")
        :ok
    end
  rescue
    exception ->
      Logger.warning("[SwarmEvents] failed to record event: #{Exception.message(exception)}")
      :ok
  end

  defp normalize_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata(_metadata), do: %{}

  defp event_sort_key(%SwarmEvent{} = event) do
    {
      timestamp_key(event.occurred_at),
      timestamp_key(event.inserted_at),
      event_rank(event.event_type),
      event.id || ""
    }
  end

  defp timestamp_key(%DateTime{} = timestamp), do: DateTime.to_unix(timestamp, :microsecond)

  defp timestamp_key(%NaiveDateTime{} = timestamp) do
    timestamp
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_unix(:microsecond)
  end

  defp timestamp_key(_timestamp), do: 0

  defp event_rank(type) when is_binary(type), do: Map.get(@event_order, type, 1_000)
  defp event_rank(_type), do: 1_000

  defp topic(company_id), do: "company:#{company_id}:swarm_events"

  defp swarm_state(%{monitor_state: monitor_state}) when is_map(monitor_state) do
    case Map.get(monitor_state, "swarm") || Map.get(monitor_state, :swarm) do
      state when is_map(state) -> state
      _ -> %{}
    end
  end

  defp swarm_state(_), do: %{}

  defp swarm_value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, swarm_atom_key(key))

  defp swarm_value(_, _), do: nil

  defp swarm_atom_key("enabled"), do: :enabled
  defp swarm_atom_key("parent_issue_id"), do: :parent_issue_id
  defp swarm_atom_key("role"), do: :role
  defp swarm_atom_key(_), do: nil

  defp truthy?(value) when value in [true, "true", 1, "1"], do: true
  defp truthy?(_), do: false
end
