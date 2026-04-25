defmodule Cympho.Secrets.Secret do
  use Ecto.Schema
  import Ecto.Changeset

  alias Cympho.Companies.Company

  @scopes ~w(company instance agent project)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "secrets" do
    belongs_to :company, Company

    field :scope, :string
    field :scope_id, :binary_id

    field :key, :string
    field :encrypted_value, :binary

    field :version, :integer, default: 1

    field :description, :string

    field :is_active, :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  def changeset(secret, attrs) do
    secret
    |> cast(attrs, [
      :company_id,
      :scope,
      :scope_id,
      :key,
      :encrypted_value,
      :version,
      :description,
      :is_active
    ])
    |> validate_required([:company_id, :scope, :key, :encrypted_value])
    |> validate_inclusion(:scope, @scopes)
    |> validate_length(:key, min: 1, max: 255)
    |> validate_number(:version, greater_than: 0)
    |> foreign_key_constraint(:company_id)
    |> maybe_require_scope_id()
  end

  def new_version_changeset(secret, attrs) do
    secret
    |> cast(attrs, [:encrypted_value, :version])
    |> validate_required([:encrypted_value, :version])
    |> validate_number(:version, greater_than: 0)
  end

  def scopes, do: @scopes

  defp maybe_require_scope_id(changeset) do
    case get_field(changeset, :scope) do
      "company" -> changeset
      "instance" -> changeset
      nil -> changeset
      _ -> validate_required(changeset, [:scope_id])
    end
  end
end
