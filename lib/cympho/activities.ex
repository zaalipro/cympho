defmodule Cympho.Activities do
  import Ecto.Query, warn: false
  alias Cympho.Repo
  alias Cympho.Activities.Activity

  def list_activities(issue_id) do
    Activity |> where(issue_id: ^issue_id) |> order_by(asc: :inserted_at) |> Repo.all()
  end

  def list_company_activities(company_id, opts \\ []) do
    action = Keyword.get(opts, :action)
    actor_type = Keyword.get(opts, :actor_type)
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)

    # Build base query joining with issues to filter by company
    query =
      from(a in Activity,
        join: i in "issues",
        on: a.issue_id == i.id,
        where: i.company_id == ^company_id,
        order_by: [desc: a.inserted_at]
      )

    # Apply action filter
    query =
      if action && action != "" do
        where(query, action: ^action)
      else
        query
      end

    # Apply actor_type filter
    query =
      if actor_type && actor_type != "" do
        where(query, actor_type: ^actor_type)
      else
        query
      end

    # Get total count before pagination
    total =
      query
      |> select([a], count(a.id))
      |> Repo.one()

    # Apply pagination and fetch results
    activities =
      query
      |> limit(^limit)
      |> offset(^offset)
      |> preload([:issue])
      |> Repo.all()

    {activities, total || 0}
  end

  def subscribe(company_id) do
    Phoenix.PubSub.subscribe(Cympho.PubSub, "company:#{company_id}:activities")
  end

  def log_activity(attrs) when is_map(attrs) do
    case %Activity{} |> Activity.changeset(attrs) |> Repo.insert() do
      {:ok, activity} ->
        company_id = issue_company_id(activity.issue_id)
        Cympho.RateLimiting.dedup_pubsub(Cympho.PubSub, "company:#{company_id}:activities", {:activity_created, activity})
        Cympho.RateLimiting.dedup_broadcast("activities:*", "activity_created", activity)
        Cympho.RateLimiting.dedup_broadcast("issue:#{activity.issue_id}", "activity_created", activity)
        {:ok, activity}

      error ->
        error
    end
  end

  def log_issue_changes(old_issue, new_issue, attrs) do
    detect_changes(old_issue, new_issue, attrs)
    |> Enum.each(fn {action, metadata} ->
      log_activity(%{
        issue_id: new_issue.id,
        actor_type: Map.get(attrs, :actor_type, "system"),
        actor_id: Map.get(attrs, :actor_id),
        action: action,
        metadata: metadata
      })
    end)

    :ok
  end

  defp detect_changes(old, new, attrs) do
    []
    |> maybe_add(:title_changed, old.title, new.title)
    |> maybe_add(:description_changed, old.description, new.description)
    |> maybe_add(:status_changed, old.status, new.status)
    |> maybe_add_assign(old, new)
    |> maybe_add(:priority_changed, old.priority, new.priority, attrs)
  end

  defp maybe_add(acc, _key, old, new) when old == new, do: acc

  defp maybe_add(acc, key, old, new),
    do: [{key, %{from: to_string(old), to: to_string(new)}} | acc]

  defp maybe_add(acc, _key, old, new, _attrs) when old == new, do: acc

  defp maybe_add(acc, key, old, new, _attrs),
    do: [{key, %{from: to_string(old), to: to_string(new)}} | acc]

  defp maybe_add_assign(acc, %{assignee_id: old_id}, %{assignee_id: new_id}) do
    cond do
      old_id == new_id ->
        acc

      is_nil(old_id) and not is_nil(new_id) ->
        [{:assigned, %{assignee_id: new_id}} | acc]

      not is_nil(old_id) and is_nil(new_id) ->
        [{:unassigned, %{previous_assignee_id: old_id}} | acc]

      true ->
        [{:assigned, %{assignee_id: new_id, previous_assignee_id: old_id}} | acc]
    end
  end

  def log_heartbeat_event(issue_id, event_type, metadata \\ %{})
      when event_type in ~w(started completed failed)a do
    action = :"heartbeat_#{event_type}"

    log_activity(%{
      issue_id: issue_id,
      actor_type: "agent",
      action: to_string(action),
      metadata: metadata
    })
  end

  def log_cost_event(issue_id, cost_amount, cost_type, metadata \\ %{}) do
    log_activity(%{
      issue_id: issue_id,
      actor_type: "system",
      action: "cost_incurred",
      metadata: Map.merge(metadata, %{amount: cost_amount, cost_type: cost_type})
    })
  end

  def log_budget_threshold(issue_id, threshold_type, current_amount, limit_amount) do
    log_activity(%{
      issue_id: issue_id,
      actor_type: "system",
      action: "budget_threshold_exceeded",
      metadata: %{
        threshold_type: threshold_type,
        current_amount: current_amount,
        limit_amount: limit_amount
      }
    })
  end

  def log_approval_event(issue_id, event_type, approval_id, actor \\ nil)
      when event_type in ~w(created approved rejected requested_changes)a do
    log_activity(%{
      issue_id: issue_id,
      actor_type: if(is_nil(actor), do: "system", else: "user"),
      actor_id: if(is_nil(actor), do: nil, else: actor.id),
      action: "approval_#{event_type}",
      metadata: %{approval_id: approval_id}
    })
  end

  def log_feedback_event(issue_id, event_type, metadata \\ %{})
      when event_type in ~w(submitted exported)a do
    log_activity(%{
      issue_id: issue_id,
      actor_type: "user",
      action: "feedback_#{event_type}",
      metadata: metadata
    })
  end

  def get_activity_statistics(issue_id) do
    activities = list_activities(issue_id)

    %{
      total: length(activities),
      by_action:
        Enum.group_by(activities, & &1.action)
        |> Enum.map(fn {k, v} -> {k, length(v)} end)
        |> Map.new(),
      by_actor_type:
        Enum.group_by(activities, & &1.actor_type)
        |> Enum.map(fn {k, v} -> {k, length(v)} end)
        |> Map.new(),
      latest: List.last(activities)
    }
  end

  defp issue_company_id(issue_id), do: Repo.one(from i in Cympho.Issues.Issue, where: i.id == ^issue_id, select: i.company_id)
end
