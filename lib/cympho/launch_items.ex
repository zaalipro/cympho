defmodule Cympho.LaunchItems do
  import Ecto.Query, warn: false
  import Ecto.Changeset

  alias Cympho.Companies
  alias Cympho.LaunchItems.LaunchItem
  alias Cympho.Repo

  def list_company_launch_items(company_id) when is_binary(company_id) do
    LaunchItem
    |> where([li], li.company_id == ^company_id)
    |> order_by([li], desc: li.is_blocked)
    |> order_by(
      [li],
      asc:
        fragment(
          "CASE ? WHEN 'planned' THEN 0 WHEN 'in_progress' THEN 1 WHEN 'completed' THEN 2 ELSE 3 END",
          li.status
        )
    )
    |> order_by([li], desc: li.updated_at, desc: li.inserted_at)
    |> Repo.all()
    |> Repo.preload(:owner_user)
  end

  def list_company_launch_items(_company_id), do: []

  def list_launch_items(company_id), do: list_company_launch_items(company_id)

  def get_company_launch_item(company_id, id) when is_binary(company_id) and is_binary(id) do
    case Repo.one(from(li in LaunchItem, where: li.company_id == ^company_id and li.id == ^id)) do
      nil -> {:error, :not_found}
      item -> {:ok, Repo.preload(item, :owner_user)}
    end
  end

  def get_company_launch_item(_company_id, _id), do: {:error, :not_found}

  def create_launch_item(attrs \\ %{}) do
    %LaunchItem{}
    |> launch_item_changeset(attrs)
    |> Repo.insert()
    |> preload_owner()
  end

  def update_launch_item(%LaunchItem{} = item, attrs) do
    item
    |> launch_item_changeset(attrs)
    |> Repo.update()
    |> preload_owner()
  end

  def delete_launch_item(%LaunchItem{} = item), do: Repo.delete(item)

  def change_launch_item(%LaunchItem{} = item, attrs \\ %{}) do
    launch_item_changeset(item, attrs)
  end

  def company_readiness(company_id) when is_binary(company_id) do
    items = list_company_launch_items(company_id)
    total = length(items)
    blocked_count = Enum.count(items, & &1.is_blocked)
    completed_count = Enum.count(items, &(&1.status == "completed"))
    in_progress_count = Enum.count(items, &(&1.status == "in_progress"))
    planned_count = Enum.count(items, &(&1.status == "planned"))
    open_count = Enum.count(items, &(&1.status != "completed"))
    active_count = Enum.count(items, &(&1.status != "completed" and not &1.is_blocked))
    blocked_titles = items |> Enum.filter(& &1.is_blocked) |> Enum.map(& &1.title)

    owner_count =
      items
      |> Enum.map(& &1.owner_user_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> length()

    %{
      total: total,
      blocked_count: blocked_count,
      completed_count: completed_count,
      in_progress_count: in_progress_count,
      planned_count: planned_count,
      open_count: open_count,
      active_count: active_count,
      owner_count: owner_count,
      blocked_titles: blocked_titles,
      completion_percent: percent(completed_count, total),
      tone: readiness_tone(total, blocked_count, completed_count),
      headline: readiness_headline(total, blocked_count, completed_count),
      detail: readiness_detail(total, blocked_count, completed_count, owner_count, active_count)
    }
  end

  def company_readiness(_company_id), do: empty_company_readiness()

  def empty_company_readiness do
    %{
      total: 0,
      blocked_count: 0,
      completed_count: 0,
      in_progress_count: 0,
      planned_count: 0,
      open_count: 0,
      active_count: 0,
      owner_count: 0,
      blocked_titles: [],
      completion_percent: 0,
      tone: :empty,
      headline: "No launch items yet",
      detail: "Create the first launch item to start tracking launch readiness."
    }
  end

  defp launch_item_changeset(item, attrs) do
    item
    |> LaunchItem.changeset(attrs)
    |> validate_owner_membership()
  end

  defp validate_owner_membership(changeset) do
    company_id = get_field(changeset, :company_id)
    owner_user_id = get_field(changeset, :owner_user_id)

    cond do
      is_nil(company_id) or is_nil(owner_user_id) ->
        changeset

      Companies.get_membership(owner_user_id, company_id) ->
        changeset

      true ->
        add_error(changeset, :owner_user_id, "must belong to the company")
    end
  end

  defp preload_owner({:ok, item}), do: {:ok, Repo.preload(item, :owner_user)}
  defp preload_owner(other), do: other

  defp percent(_part, 0), do: 0
  defp percent(part, total), do: round(part * 100 / total)

  defp readiness_tone(0, _blocked, _completed), do: :empty
  defp readiness_tone(_total, blocked, _completed) when blocked > 0, do: :danger
  defp readiness_tone(total, _blocked, completed) when total > 0 and completed == total, do: :ok
  defp readiness_tone(_total, _blocked, completed) when completed > 0, do: :warning
  defp readiness_tone(_total, _blocked, _completed), do: :neutral

  defp readiness_headline(0, _blocked, _completed), do: "No launch items yet"

  defp readiness_headline(total, blocked, _completed) when blocked > 0 do
    "#{blocked}/#{total} blocked"
  end

  defp readiness_headline(total, _blocked, completed) when total > 0 and completed == total do
    "Launch ready"
  end

  defp readiness_headline(total, _blocked, completed) when completed > 0 do
    "#{completed}/#{total} completed"
  end

  defp readiness_headline(total, _blocked, _completed), do: "#{total} item#{plural(total)} active"

  defp readiness_detail(0, _blocked, _completed, _owners, _active),
    do: "Create the first launch item to start tracking launch readiness."

  defp readiness_detail(_total, blocked, completed, owners, active) when blocked > 0 do
    "#{active} open, #{blocked} blocked, #{completed} completed, and #{owners} owner#{plural(owners)} assigned."
  end

  defp readiness_detail(total, _blocked, _completed, owners, active) when total > 0 do
    "#{active} open and #{owners} owner#{plural(owners)} assigned."
  end

  defp plural(1), do: ""
  defp plural(_), do: "s"
end
