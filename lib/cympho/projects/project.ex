defmodule Cympho.Projects.Project do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "projects" do
    field :name, :string
    field :description, :string
    field :status, Ecto.Enum, values: [:active, :archived], default: :active
    field :prefix, :string
    field :repo_url, :string
    field :github_webhook_secret, :string
    field :color, :string
    field :settings, :map, default: %{}

    belongs_to :company, Cympho.Companies.Company

    timestamps(type: :utc_datetime)
  end

  @editable_fields [
    :name,
    :description,
    :status,
    :prefix,
    :repo_url,
    :github_webhook_secret,
    :color,
    :settings
  ]

  def changeset(%__MODULE__{id: nil} = project, attrs) do
    project
    |> cast(attrs, [:company_id | @editable_fields])
    |> validate_changes()
  end

  def changeset(%__MODULE__{} = project, attrs), do: update_changeset(project, attrs)

  @doc """
  Request-safe changeset for an existing project.

  A project's tenant is immutable after creation, so `company_id` is
  deliberately excluded even when it is present in user-supplied parameters.
  """
  def update_changeset(project, attrs) do
    project
    |> cast(attrs, @editable_fields)
    |> validate_changes()
  end

  defp validate_changes(changeset) do
    changeset
    |> validate_required([:name, :prefix, :company_id])
    |> foreign_key_constraint(:company_id)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_length(:prefix, min: 2, max: 10)
    |> validate_format(:prefix, ~r/^[A-Z]+$/, message: "must be uppercase, 2-10 characters")
    |> validate_repo_url()
    |> validate_color()
    |> unique_constraint(:prefix, name: :projects_company_id_prefix_index)
    |> assoc_constraint(:company)
  end

  defp validate_color(changeset) do
    case get_change(changeset, :color) do
      nil ->
        changeset

      "" ->
        put_change(changeset, :color, nil)

      hex ->
        if String.match?(hex, ~r/^#[0-9a-fA-F]{6}$/) do
          put_change(changeset, :color, String.downcase(hex))
        else
          add_error(changeset, :color, "must be a 6-digit hex like #D97757")
        end
    end
  end

  defp validate_repo_url(changeset) do
    case get_change(changeset, :repo_url) do
      nil ->
        changeset

      "" ->
        put_change(changeset, :repo_url, nil)

      url ->
        if String.match?(url, ~r{^https?://}) do
          put_change(changeset, :repo_url, String.trim_trailing(url, "/"))
        else
          add_error(changeset, :repo_url, "must start with http:// or https://")
        end
    end
  end
end
