defmodule Cympho.GovernanceAuditLogs do
  @moduledoc """
  The GovernanceAuditLogs context for managing audit trails of all governance decisions.
  """

  import Ecto.Query, warn: false
  alias Cympho.Repo
  alias Cympho.GovernanceAuditLogs.GovernanceAuditLog

  @doc """
  Returns the list of governance audit logs.
  """
  def list_governance_audit_logs(opts \\ %{}) do
    query = from(l in GovernanceAuditLog, order_by: [desc: l.inserted_at])

    query =
      Enum.reduce(opts, query, fn
        {:action_type, type}, q ->
          where(q, [l], l.action_type == ^type)

        {:actor_type, type}, q ->
          where(q, [l], l.actor_type == ^type)

        {:actor_id, id}, q ->
          where(q, [l], l.actor_id == ^id)

        {:resource_type, type}, q ->
          where(q, [l], l.resource_type == ^type)

        {:resource_id, id}, q ->
          where(q, [l], l.resource_id == ^id)

        {:limit, limit}, q ->
          limit(q, ^limit)

        _, q ->
          q
      end)

    Repo.all(query)
  end

  @doc """
  Gets a single governance audit log.
  """
  def get_governance_audit_log!(id), do: Repo.get!(GovernanceAuditLog, id)

  @doc """
  Creates a governance audit log entry.
  """
  def create_governance_audit_log(attrs) do
    %GovernanceAuditLog{}
    |> GovernanceAuditLog.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Logs a governance action with automatic context extraction.
  """
  def log_action(action_type, actor, decision, opts \\ []) do
    {actor_type, actor_id} = extract_actor_info(actor)
    {resource_type, resource_id} = extract_resource_info(opts[:resource])

    attrs = %{
      action_type: action_type,
      actor_type: actor_type,
      actor_id: actor_id,
      resource_type: resource_type,
      resource_id: resource_id,
      decision: decision,
      reasoning: Keyword.get(opts, :reasoning),
      metadata: Keyword.get(opts, :metadata, %{}),
      ip_address: Keyword.get(opts, :ip_address),
      user_agent: Keyword.get(opts, :user_agent)
    }

    case create_governance_audit_log(attrs) do
      {:ok, log} ->
        Phoenix.PubSub.broadcast(
          Cympho.PubSub,
          "governance_audit",
          {:audit_log_created, log}
        )

        {:ok, log}

      error ->
        error
    end
  end

  @doc """
  Subscribes to governance audit log events.
  """
  def subscribe do
    Phoenix.PubSub.subscribe(Cympho.PubSub, "governance_audit")
  end

  defp extract_actor_info(%{__struct__: type, id: id}) when is_binary(id) do
    actor_type =
      type
      |> Module.split()
      |> List.last()
      |> String.downcase()

    {actor_type, id}
  end

  defp extract_actor_info({type, id}) when is_binary(type) and is_binary(id) do
    {String.downcase(type), id}
  end

  defp extract_actor_info(nil), do: {"system", "00000000-0000-0000-0000-000000000000"}

  defp extract_resource_info(nil), do: {nil, nil}

  defp extract_resource_info(%{__struct__: type, id: id}) when is_binary(id) do
    resource_type =
      type
      |> Module.split()
      |> List.last()
      |> String.downcase()

    {resource_type, id}
  end

  defp extract_resource_info({type, id}) when is_binary(type) and is_binary(id) do
    {String.downcase(type), id}
  end
end
