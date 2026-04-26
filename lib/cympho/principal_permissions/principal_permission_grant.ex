defmodule Cympho.PrincipalPermissions.PrincipalPermissionGrant do
  @moduledoc """
  Schema for principal permission grants.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "principal_permission_grants" do
    field :principal_id, :string
    field :principal_type, :string
    field :permission, :string
    field :scope_type, :string
    field :scope_id, :string
    field :granted_by_id, :string
    field :granted_by_type, :string
    field :expires_at, :utc_datetime
    field :status, :string, default: "active"
    field :metadata, :map, default: %{}

    belongs_to :board_approval, Cympho.BoardApprovals.BoardApproval

    timestamps(type: :utc_datetime)
  end

  def changeset(grant, attrs) do
    grant
    |> cast(attrs, [
      :principal_id,
      :principal_type,
      :permission,
      :scope_type,
      :scope_id,
      :granted_by_id,
      :granted_by_type,
      :expires_at,
      :status,
      :metadata,
      :board_approval_id
    ])
    |> validate_required([:principal_id, :principal_type, :permission, :status])
    |> validate_inclusion(:status, ["active", "revoked", "expired"])
    |> validate_expiration()
    |> validate_permission_format()
  end

  defp validate_expiration(changeset) do
    case get_change(changeset, :expires_at) do
      nil ->
        changeset

      expires_at ->
        if DateTime.compare(expires_at, DateTime.utc_now()) == :lt do
          add_error(changeset, :expires_at, "cannot be in the past")
        else
          changeset
        end
    end
  end

  defp validate_permission_format(changeset) do
    case get_change(changeset, :permission) do
      nil -> changeset
      _permission -> validate_format(changeset, :permission, ~r/^[a-z_]+(\.[a-z_]+)*$/)
    end
  end

  @doc """
  Check if a grant is currently active.
  """
  def active?(%__MODULE__{status: "active", expires_at: nil}), do: true
  def active?(%__MODULE__{status: "active", expires_at: expires_at}) do
    DateTime.compare(expires_at, DateTime.utc_now()) == :gt
  end
  def active?(%__MODULE__{}), do: false
end
