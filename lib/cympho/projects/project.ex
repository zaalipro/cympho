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
    field :settings, :map, default: %{}

    belongs_to :company, Cympho.Companies.Company

    timestamps(type: :utc_datetime)
  end

  def changeset(project, attrs) do
    project
    |> cast(attrs, [
      :name,
      :description,
      :status,
      :prefix,
      :repo_url,
      :github_webhook_secret,
      :settings,
      :company_id
    ])
    |> validate_required([:name, :prefix])
    |> validate_length(:name, min: 1, max: 255)
    |> validate_length(:prefix, min: 2, max: 10)
    |> validate_format(:prefix, ~r/^[A-Z]+$/, message: "must be uppercase, 2-10 characters")
    |> validate_repo_url()
    |> unique_constraint(:prefix)
    |> assoc_constraint(:company)
  end

  defp validate_repo_url(changeset) do
    case get_change(changeset, :repo_url) do
      nil -> changeset
      "" -> put_change(changeset, :repo_url, nil)
      url ->
        if String.match?(url, ~r{^https?://}) do
          put_change(changeset, :repo_url, String.trim_trailing(url, "/"))
        else
          add_error(changeset, :repo_url, "must start with http:// or https://")
        end
    end
  end
end
