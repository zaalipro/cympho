defmodule Cympho.RecentSearches.RecentSearch do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "recent_searches" do
    field :query, :string
    field :filters, :map, default: %{}
    field :search_count, :integer, default: 1

    belongs_to :user, Cympho.Accounts.User
    belongs_to :company, Cympho.Companies.Company

    timestamps(type: :utc_datetime)
  end

  def changeset(recent_search, attrs) do
    recent_search
    |> cast(attrs, [:query, :filters, :search_count, :user_id, :company_id])
    |> validate_required([:query, :user_id, :company_id])
    |> validate_length(:query, min: 1, max: 500)
  end

  def update_count_changeset(recent_search) do
    recent_search
    |> change()
    |> update_change(:search_count, &(&1 + 1))
  end
end
