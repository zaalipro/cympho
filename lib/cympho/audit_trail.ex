defmodule Cympho.AuditTrail do
  import Ecto.Query, warn: false
  alias Cympho.Repo
  alias Cympho.AuditTrail.AuditEvent

  @doc """
  Records an audit event.

  ## Examples

      iex> AuditTrail.record_event(%{
      ...>   company_id: "123",
      ...>   event_type: "issue_state_transition",
      ...>   actor_type: "agent",
      ...>   actor_id: "456",
      ...>   resource_type: "issue",
      ...>   resource_id: "789",
      ...>   payload: %{"from" => "queued", "to" => "in_progress"},
      ...>   ip_address: "10.0.0.1"
      ...> })
      {:ok, %AuditEvent{}}

  """
  def record_event(attrs) when is_map(attrs) do
    %AuditEvent{}
    |> AuditEvent.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Lists audit events for a company with optional filters.

  ## Options

    * `:event_type` - Filter by event type
    * `:actor_type` - Filter by actor type
    * `:actor_id` - Filter by specific actor
    * `:resource_type` - Filter by resource type
    * `:resource_id` - Filter by specific resource
    * `:start_date` - Filter events after this date
    * `:end_date` - Filter events before this date
    * `:limit` - Number of results to return (default: 50)
    * `:offset` - Number of results to skip (default: 0)

  ## Examples

      iex> AuditTrail.list_company_events("company-123", event_type: "issue_state_transition", limit: 10)
      {[%AuditEvent{}, ...], 150}

  """
  def list_company_events(company_id, opts \\ []) do
    event_type = Keyword.get(opts, :event_type)
    actor_type = Keyword.get(opts, :actor_type)
    actor_id = Keyword.get(opts, :actor_id)
    resource_type = Keyword.get(opts, :resource_type)
    resource_id = Keyword.get(opts, :resource_id)
    start_date = Keyword.get(opts, :start_date)
    end_date = Keyword.get(opts, :end_date)
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)

    query =
      from(e in AuditEvent,
        where: e.company_id == ^company_id,
        order_by: [desc: e.inserted_at]
      )

    query =
      if event_type && event_type != "" do
        where(query, event_type: ^event_type)
      else
        query
      end

    query =
      if actor_type && actor_type != "" do
        where(query, actor_type: ^actor_type)
      else
        query
      end

    query =
      if actor_id && actor_id != "" do
        where(query, actor_id: ^actor_id)
      else
        query
      end

    query =
      if resource_type && resource_type != "" do
        where(query, resource_type: ^resource_type)
      else
        query
      end

    query =
      if resource_id && resource_id != "" do
        where(query, resource_id: ^resource_id)
      else
        query
      end

    query =
      if start_date do
        where(query, [e], e.inserted_at >= ^start_date)
      else
        query
      end

    query =
      if end_date do
        where(query, [e], e.inserted_at <= ^end_date)
      else
        query
      end

    total =
      query
      |> exclude(:order_by)
      |> select([e], count(e.id))
      |> Repo.one()

    events =
      query
      |> limit(^limit)
      |> offset(^offset)
      |> Repo.all()

    {events, total || 0}
  end

  @doc """
  Lists audit events for a specific resource.

  ## Examples

      iex> AuditTrail.list_resource_history("issue-123", "issue")
      [%AuditEvent{}, ...]

  """
  def list_resource_history(resource_id, resource_type, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    from(e in AuditEvent,
      where: e.resource_id == ^resource_id,
      where: e.resource_type == ^resource_type,
      order_by: [desc: e.inserted_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc """
  Lists audit events performed by a specific actor.

  ## Examples

      iex> AuditTrail.list_actor_history("agent-456", "agent", company_id: "company-123")
      [%AuditEvent{}, ...]

  """
  def list_actor_history(actor_id, actor_type, opts \\ []) do
    company_id = Keyword.get(opts, :company_id)
    limit = Keyword.get(opts, :limit, 100)

    query =
      from(e in AuditEvent,
        where: e.actor_id == ^actor_id,
        where: e.actor_type == ^actor_type,
        order_by: [desc: e.inserted_at],
        limit: ^limit
      )

    query =
      if company_id do
        where(query, company_id: ^company_id)
      else
        query
      end

    Repo.all(query)
  end

  @doc """
  Returns distinct event types for a company.

  ## Examples

      iex> AuditTrail.list_event_types("company-123")
      ["issue_state_transition", "agent_paused", ...]

  """
  def list_event_types(company_id) do
    from(e in AuditEvent,
      where: e.company_id == ^company_id,
      distinct: e.event_type,
      select: e.event_type,
      order_by: e.event_type
    )
    |> Repo.all()
  end

  @doc """
  Returns statistics about audit events for a company.

  ## Examples

      iex> AuditTrail.get_statistics("company-123")
      %{total: 1000, by_event_type: %{"issue_state_transition" => 500, ...}}

  """
  def get_statistics(company_id, opts \\ []) do
    start_date = Keyword.get(opts, :start_date)
    end_date = Keyword.get(opts, :end_date)

    query =
      from(e in AuditEvent,
        where: e.company_id == ^company_id
      )

    query =
      if start_date do
        where(query, [e], e.inserted_at >= ^start_date)
      else
        query
      end

    query =
      if end_date do
        where(query, [e], e.inserted_at <= ^end_date)
      else
        query
      end

    total =
      query
      |> select([e], count(e.id))
      |> Repo.one()

    by_event_type =
      query
      |> group_by([e], e.event_type)
      |> select([e], {e.event_type, count(e.id)})
      |> Repo.all()
      |> Map.new()

    by_actor_type =
      query
      |> group_by([e], e.actor_type)
      |> select([e], {e.actor_type, count(e.id)})
      |> Repo.all()
      |> Map.new()

    %{
      total: total || 0,
      by_event_type: by_event_type,
      by_actor_type: by_actor_type
    }
  end
end
