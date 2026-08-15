defmodule Cympho.PrincipalPermissions do
  @moduledoc """
  The PrincipalPermissions context for managing permission grants to principals.
  """

  import Ecto.Query, warn: false
  alias Cympho.Repo
  alias Cympho.PrincipalPermissions.PrincipalPermissionGrant
  alias Cympho.GovernanceAuditLogs

  @doc """
  Returns the list of principal permission grants for a company.
  """
  def list_principal_permission_grants(company_id, opts \\ %{}) when is_binary(company_id) do
    query =
      from(p in PrincipalPermissionGrant,
        where: p.company_id == ^company_id,
        order_by: [desc: p.inserted_at]
      )

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
  Gets a single principal permission grant in the given company.
  """
  def get_company_principal_permission_grant(company_id, id) do
    case Repo.one(
           from p in PrincipalPermissionGrant,
             where: p.id == ^id and p.company_id == ^company_id
         ) do
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
          resource: nil,
          metadata: %{
            grant_id: grant.id,
            permission: grant.permission,
            principal: "#{grant.principal_type}:#{grant.principal_id}",
            scope: grant.scope_type && "#{grant.scope_type}:#{grant.scope_id}",
            expires_at: grant.expires_at
          }
        )

        Cympho.PubSubGuard.company_broadcast(
          grant.company_id,
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
      company_id: board_approval.company_id,
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
          resource: nil,
          reasoning: reason,
          metadata: %{
            grant_id: revoked.id,
            permission: revoked.permission,
            principal: "#{revoked.principal_type}:#{revoked.principal_id}"
          }
        )

        Cympho.PubSubGuard.company_broadcast(
          revoked.company_id,
          "principal_permissions",
          {:permission_grant_revoked, revoked}
        )

        {:ok, revoked}

      error ->
        error
    end
  end

  @doc """
  Checks if a principal has a specific active permission in a company.

  `opts` must include `:company_id`. Blank-scope grants apply only inside
  that company.
  """
  def has_permission?(principal_id, principal_type, permission, opts \\ %{}) do
    case opts_get(opts, :company_id) do
      company_id when is_binary(company_id) and company_id != "" ->
        do_has_permission?(principal_id, principal_type, permission, company_id, opts)

      _ ->
        false
    end
  end

  defp do_has_permission?(principal_id, principal_type, permission, company_id, opts) do
    base_query =
      from(p in PrincipalPermissionGrant,
        where:
          p.company_id == ^company_id and p.principal_id == ^principal_id and
            p.principal_type == ^principal_type and p.permission == ^permission and
            p.status == "active"
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
  Checks if a principal has an active permission that applies to one of the given scopes.

  Blank-scope grants apply only to resources in that grant's `company_id`.
  Scoped grants must match one of the supplied `{scope_type, scope_id}` pairs.
  Expired grants are ignored. A `company` scope is required.
  """
  def has_permission_in_scope?(principal_id, principal_type, permission, scopes \\ []) do
    scopes = normalize_scopes(scopes)

    case company_id_from_scopes(scopes) do
      nil ->
        false

      company_id ->
        list_principal_permission_grants(company_id,
          principal_id: principal_id,
          principal_type: principal_type,
          permission: permission,
          active: true,
          not_expired: true
        )
        |> Enum.any?(&grant_applies_to_scope?(&1, scopes))
    end
  end

  @doc """
  Gets all active permissions for a principal in a company.
  """
  def get_principal_permissions(company_id, principal_id, principal_type)
      when is_binary(company_id) do
    from(p in PrincipalPermissionGrant,
      where:
        p.company_id == ^company_id and p.principal_id == ^principal_id and
          p.principal_type == ^principal_type and p.status == "active" and
          (is_nil(p.expires_at) or p.expires_at > ^DateTime.utc_now()),
      order_by: [desc: p.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Checks and expires outdated permission grants.
  """
  def check_expired_grants do
    from(p in PrincipalPermissionGrant,
      where:
        p.status == "active" and not is_nil(p.expires_at) and p.expires_at < ^DateTime.utc_now()
    )
    |> Repo.update_all(set: [status: "expired"])
  end

  @doc """
  Subscribes to this company's principal permission events.

  Scoped per company: the previous global topic delivered every tenant's
  grants to every subscriber.
  """
  def subscribe(company_id) when is_binary(company_id) and company_id != "" do
    Phoenix.PubSub.subscribe(Cympho.PubSub, "company:#{company_id}:principal_permissions")
  end

  defp normalize_scopes(scopes) when is_list(scopes) do
    scopes
    |> Enum.flat_map(fn
      {type, id} when not is_nil(id) ->
        [{to_string(type), to_string(id)}]

      %{scope_type: type, scope_id: id} when not is_nil(type) and not is_nil(id) ->
        [{to_string(type), to_string(id)}]

      _ ->
        []
    end)
    |> MapSet.new()
  end

  defp normalize_scopes(_), do: MapSet.new()

  defp grant_applies_to_scope?(%PrincipalPermissionGrant{} = grant, scopes) do
    PrincipalPermissionGrant.active?(grant) and
      (unscoped_in_company?(grant, scopes) or
         MapSet.member?(scopes, {grant.scope_type, grant.scope_id}))
  end

  defp unscoped_in_company?(%PrincipalPermissionGrant{} = grant, scopes) do
    unscoped_grant?(grant) and
      MapSet.member?(scopes, {"company", to_string(grant.company_id)})
  end

  defp unscoped_grant?(%PrincipalPermissionGrant{scope_type: scope_type, scope_id: scope_id}) do
    blank?(scope_type) and blank?(scope_id)
  end

  defp company_id_from_scopes(scopes) do
    Enum.find_value(scopes, fn
      {"company", id} -> id
      _ -> nil
    end)
  end

  defp opts_get(opts, key) when is_map(opts) do
    Map.get(opts, key) || Map.get(opts, Atom.to_string(key))
  end

  defp opts_get(opts, key) when is_list(opts), do: Keyword.get(opts, key)
  defp opts_get(_opts, _key), do: nil

  defp blank?(value), do: value in [nil, ""]

  defp actor_id({_, id}), do: id
  defp actor_id(nil), do: nil
  defp actor_id(%{id: id}), do: id

  defp actor_type({type, _}), do: type
  defp actor_type(nil), do: nil

  defp actor_type(%{__struct__: type}),
    do: type |> Module.split() |> List.last() |> String.downcase()

  defp parse_expires_at(nil), do: nil
  defp parse_expires_at(datetime), do: datetime
end
