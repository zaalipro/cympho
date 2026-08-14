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
    |> validate_scope_in_company()
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

  defp validate_scope_in_company(changeset) do
    scope = get_field(changeset, :scope)
    company_id = get_field(changeset, :company_id)
    scope_id = get_field(changeset, :scope_id)

    cond do
      scope not in ["agent", "project"] ->
        changeset

      not is_binary(company_id) or not is_binary(scope_id) ->
        changeset

      scope == "agent" ->
        case Cympho.Agents.get_company_agent(company_id, scope_id) do
          {:ok, _} -> changeset
          {:error, _} -> add_error(changeset, :scope_id, "is not in this company")
        end

      scope == "project" ->
        case Cympho.Projects.get_company_project(company_id, scope_id) do
          {:ok, _} -> changeset
          {:error, _} -> add_error(changeset, :scope_id, "is not in this company")
        end
    end
  end
end
