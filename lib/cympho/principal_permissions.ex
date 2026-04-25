defmodule Cympho.PrincipalPermissions do
  @moduledoc """
  The PrincipalPermissions context for managing permission grants to principals.
  """

  import Ecto.Query, warn: false
  alias Cympho.Repo
  alias Cympho.PrincipalPermissions.PrincipalPermissionGrant
  alias Cympho.GovernanceAuditLogs

  @doc """
  Returns the list of principal permission grants.
  """
  def list_principal_permission_grants(opts \\ %{}) do
    query = from(p in PrincipalPermissionGrant, order_by: [desc: p.inserted_at])

    query =
      Enum.reduce(opts, query, fn
        {:principal_id, id}, q ->
          where(q, [p], p.principal_id == ^id)

        {:principal_type, type}, q ->
          where(q, [p], p.principal_type == ^type)

        {:permission, permission}, q ->
          where(q, [p], p.permission == ^permission)

        {:scope_type, type}, q ->
          where(q, [p], p.scope_type == ^type)

        {:scope_id, id}, q ->
          where(q, [p], p.scope_id == ^id)

        {:status, status}, q ->
          where(q, [p], p.status == ^status)

        {:active, true}, q ->
          where(q, [p], p.status == "active")

        {:not_expired, true}, q ->
          where(q, [p], is_nil(p.expires_at) or p.expires_at > ^DateTime.utc_now())

        _, q ->
          q
      end)

    Repo.all(query)
  end

  @doc """
  Gets a single principal permission grant.
  """
  def get_principal_permission_grant!(id), do: Repo.get!(PrincipalPermissionGrant, id)

  def get_principal_permission_grant(id) do
    case Repo.get(PrincipalPermissionGrant, id) do
      nil -> {:error, :not_found}
      grant -> {:ok, grant}
    end
  end

  @doc """
  Creates a principal permission grant.
  """
  def create_permission_grant(attrs, actor \\ nil) do
    %PrincipalPermissionGrant{}
    |> PrincipalPermissionGrant.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, grant} ->
        GovernanceAuditLogs.log_action(
          "permission_granted",
          actor || {"system", "system"},
          "Permission granted: #{grant.permission} to #{grant.principal_type}:#{grant.principal_id}",
          resource: grant,
          metadata: %{
            permission: grant.permission,
            principal: "#{grant.principal_type}:#{grant.principal_id}",
            scope: grant.scope_type && "#{grant.scope_type}:#{grant.scope_id}",
            expires_at: grant.expires_at
          }
        )

        Phoenix.PubSub.broadcast(
          Cympho.PubSub,
          "principal_permissions",
          {:permission_grant_created, grant}
        )

        {:ok, grant}

      error ->
        error
    end
  end

  @doc """
  Creates a permission grant via board approval.
  """
  def create_permission_grant_from_approval(board_approval, actor \\ nil) do
    principal_id = get_in(board_approval.proposal_data, ["principal_id"])
    principal_type = get_in(board_approval.proposal_data, ["principal_type"]) || "user"
    permission = get_in(board_approval.proposal_data, ["permission"])
    scope_type = get_in(board_approval.proposal_data, ["scope_type"])
    scope_id = get_in(board_approval.proposal_data, ["scope_id"])
    expires_at = get_in(board_approval.proposal_data, ["expires_at"])

    attrs = %{
      principal_id: principal_id,
      principal_type: principal_type,
      permission: permission,
      scope_type: scope_type,
      scope_id: scope_id,
      granted_by_id: actor_id(actor),
      granted_by_type: actor_type(actor),
      board_approval_id: board_approval.id,
      expires_at: parse_expires_at(expires_at),
      status: "active",
      metadata: %{
        granted_via: "board_approval",
        board_approval_title: board_approval.title
      }
    }

    create_permission_grant(attrs, actor)
  end

  @doc """
  Revokes a permission grant.
  """
  def revoke_permission_grant(%PrincipalPermissionGrant{} = grant, reason \\ nil, actor \\ nil) do
    grant
    |> Ecto.Changeset.change(%{status: "revoked"})
    |> Repo.update()
    |> case do
      {:ok, revoked} ->
        GovernanceAuditLogs.log_action(
          "permission_revoked",
          actor || {"system", "system"},
          "Permission revoked: #{revoked.permission} from #{revoked.principal_type}:#{revoked.principal_id}",
          resource: revoked,
          reasoning: reason,
          metadata: %{
            permission: revoked.permission,
            principal: "#{revoked.principal_type}:#{revoked.principal_id}"
          }
        )

        Phoenix.PubSub.broadcast(
          Cympho.PubSub,
          "principal_permissions",
          {:permission_grant_revoked, revoked}
        )

        {:ok, revoked}

      error ->
        error
    end
  end

  @doc """
  Checks if a principal has a specific active permission.
  """
  def has_permission?(principal_id, principal_type, permission, opts \\ %{}) do
    base_query =
      from(p in PrincipalPermissionGrant,
        where:
          p.principal_id == ^principal_id and p.principal_type == ^principal_type and
            p.permission == ^permission and p.status == "active"
      )

    query =
      Enum.reduce(opts, base_query, fn
        {:scope_type, type}, q ->
          where(q, [p], p.scope_type == ^type)

        {:scope_id, id}, q ->
          where(q, [p], p.scope_id == ^id)

        {:check_expiration, true}, q ->
          where(q, [p], is_nil(p.expires_at) or p.expires_at > ^DateTime.utc_now())

        _, q ->
          q
      end)

    Repo.exists?(query)
  end

  @doc """
  Gets all active permissions for a principal.
  """
  def get_principal_permissions(principal_id, principal_type) do
    from(p in PrincipalPermissionGrant,
      where:
        p.principal_id == ^principal_id and p.principal_type == ^principal_type and
          p.status == "active" and (is_nil(p.expires_at) or p.expires_at > ^DateTime.utc_now()),
      order_by: [desc: p.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Checks and expires outdated permission grants.
  """
  def check_expired_grants do
    from(p in PrincipalPermissionGrant,
      where: p.status == "active" and not is_nil(p.expires_at) and p.expires_at < ^DateTime.utc_now()
    )
    |> Repo.update_all(set: [status: "expired"])
  end

  @doc """
  Subscribes to principal permission events.
  """
  def subscribe do
    Phoenix.PubSub.subscribe(Cympho.PubSub, "principal_permissions")
  end

  defp actor_id({_, id}), do: id
  defp actor_id(nil), do: nil
  defp actor_id(%{id: id}), do: id

  defp actor_type({type, _}), do: type
  defp actor_type(nil), do: nil
  defp actor_type(%{__struct__: type}), do: type |> Module.split() |> List.last() |> String.downcase()

  defp parse_expires_at(nil), do: nil
  defp parse_expires_at(datetime), do: datetime
end
