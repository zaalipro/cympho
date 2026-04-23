defmodule Cympho.Activities do
  import Ecto.Query, warn: false
  alias Cympho.Repo
  alias Cympho.Activities.Activity

  def list_activities(issue_id) do
    Activity |> where(issue_id: ^issue_id) |> order_by(asc: :inserted_at) |> Repo.all()
  end

  def subscribe do
    Phoenix.PubSub.subscribe(Cympho.PubSub, "activities")
  end

  def log_activity(attrs) when is_map(attrs) do
    case %Activity{} |> Activity.changeset(attrs) |> Repo.insert() do
      {:ok, activity} ->
        Phoenix.PubSub.broadcast(Cympho.PubSub, "activities", {:activity_created, activity})
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
end
