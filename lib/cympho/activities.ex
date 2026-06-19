defmodule Cympho.Activities do
  import Ecto.Query, warn: false
  alias Cympho.Repo
  alias Cympho.Activities.Activity
  alias Cympho.Issues.Issue

  @default_list_limit 100
  @default_company_timeline_limit 50
  @max_company_timeline_limit 200

  def list_activities(issue_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_list_limit)

    Activity
    |> where(issue_id: ^issue_id)
    |> order_by(asc: :inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def list_company_activities(company_id, opts \\ []) do
    limit = opts |> Keyword.get(:limit, @default_company_timeline_limit) |> clamp_limit()
    offset = opts |> Keyword.get(:offset, 0) |> max(0)

    query =
      company_activities_base_query(company_id, opts)
      |> order_by([a], desc: a.inserted_at)

    # Get total count before pagination
    total =
      query
      |> exclude(:order_by)
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

  def company_activity_snapshot(company_id, opts \\ []) do
    query = company_activities_base_query(company_id, opts)

    total =
      query
      |> select([a], count(a.id))
      |> Repo.one()

    by_action =
      query
      |> group_by([a], a.action)
      |> select([a], {a.action, count(a.id)})
      |> Repo.all()
      |> Map.new()

    latest =
      query
      |> order_by([a], desc: a.inserted_at)
      |> limit(1)
      |> Repo.one()
      |> case do
        nil -> nil
        activity -> Repo.preload(activity, [:issue])
      end

    %{total: total || 0, by_action: by_action, latest: latest}
  end

  @doc """
  Keyset (infinite-scroll) page of a company's activities, newest first.

  Scopes through the issue join (robust to legacy rows whose `company_id` is
  null) and returns a `Cympho.Pagination.Page` with `:issue` preloaded.
  """
  def list_company_activities_page(company_id, opts \\ []) do
    company_activities_base_query(company_id, opts)
    |> Cympho.Pagination.page(
      limit: Keyword.get(opts, :limit, 50),
      after: Keyword.get(opts, :after),
      cursor_fields: [{:inserted_at, :desc}, {:id, :desc}]
    )
    |> preload_page_issues()
  end

  defp maybe_where_action(query, action) when action in [nil, ""], do: query
  defp maybe_where_action(query, action), do: where(query, [a], a.action == ^action)

  defp maybe_where_actor_type(query, actor_type) when actor_type in [nil, ""], do: query

  defp maybe_where_actor_type(query, actor_type),
    do: where(query, [a], a.actor_type == ^actor_type)

  defp maybe_where_since(query, nil), do: query

  defp maybe_where_since(query, %DateTime{} = since) do
    since = DateTime.truncate(since, :second)
    where(query, [a], a.inserted_at > ^since)
  end

  defp company_activities_base_query(company_id, opts) do
    from(a in Activity,
      join: i in Issue,
      on: a.issue_id == i.id,
      where: i.company_id == ^company_id
    )
    |> maybe_where_action(Keyword.get(opts, :action))
    |> maybe_where_actor_type(Keyword.get(opts, :actor_type))
    |> maybe_where_since(Keyword.get(opts, :since))
  end

  defp clamp_limit(limit) when is_integer(limit),
    do: limit |> max(1) |> min(@max_company_timeline_limit)

  defp clamp_limit(_limit), do: @default_company_timeline_limit

  defp preload_page_issues(%Cympho.Pagination.Page{} = page) do
    %{page | entries: Repo.preload(page.entries, [:issue])}
  end

  def subscribe(company_id) do
    Phoenix.PubSub.subscribe(Cympho.PubSub, "company:#{company_id}:activities")
  end

  def log_activity(attrs) when is_map(attrs) do
    attrs = put_company_id(attrs)

    case %Activity{} |> Activity.changeset(attrs) |> Repo.insert() do
      {:ok, activity} ->
        company_id = activity.company_id || issue_company_id(activity.issue_id)

        Cympho.RateLimiting.dedup_pubsub(
          Cympho.PubSub,
          "company:#{company_id}:activities",
          {:activity_created, activity}
        )

        Cympho.RateLimiting.dedup_broadcast("activities:*", "activity_created", activity)

        Cympho.RateLimiting.dedup_broadcast(
          "issue:#{activity.issue_id}",
          "activity_created",
          activity
        )

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
        company_id: new_issue.company_id,
        actor_type: Map.get(attrs, :actor_type, "system"),
        actor_id: Map.get(attrs, :actor_id),
        action: to_string(action),
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
    total =
      Repo.one(from a in Activity, where: a.issue_id == ^issue_id, select: count(a.id)) || 0

    by_action =
      Repo.all(
        from a in Activity,
          where: a.issue_id == ^issue_id,
          group_by: a.action,
          select: {a.action, count(a.id)}
      )
      |> Map.new()

    by_actor_type =
      Repo.all(
        from a in Activity,
          where: a.issue_id == ^issue_id,
          group_by: a.actor_type,
          select: {a.actor_type, count(a.id)}
      )
      |> Map.new()

    latest =
      Repo.one(
        from a in Activity,
          where: a.issue_id == ^issue_id,
          order_by: [desc: a.inserted_at],
          limit: 1
      )

    %{total: total, by_action: by_action, by_actor_type: by_actor_type, latest: latest}
  end

  defp issue_company_id(issue_id),
    do: Repo.one(from i in Cympho.Issues.Issue, where: i.id == ^issue_id, select: i.company_id)

  defp put_company_id(%{company_id: company_id} = attrs) when not is_nil(company_id), do: attrs

  defp put_company_id(%{"company_id" => company_id} = attrs) when not is_nil(company_id),
    do: attrs

  defp put_company_id(%{issue_id: issue_id} = attrs) when not is_nil(issue_id) do
    Map.put(attrs, :company_id, issue_company_id(issue_id))
  end

  defp put_company_id(%{"issue_id" => issue_id} = attrs) when not is_nil(issue_id) do
    Map.put(attrs, "company_id", issue_company_id(issue_id))
  end

  defp put_company_id(attrs), do: attrs
end
