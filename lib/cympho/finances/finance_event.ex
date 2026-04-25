defmodule Cympho.Finances.FinanceEvent do
  use Ecto.Schema
  import Ecto.Changeset

  alias Cympho.Companies.Company
  alias Cympho.Finances.TokenUsage

  @event_types ~w(token_usage charge credit refund adjustment)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "finance_events" do
    belongs_to :company, Company
    belongs_to :token_usage, TokenUsage

    field :event_type, :string
    field :amount_usd, :decimal
    field :currency, :string, default: "USD"

    field :description, :string
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  def changeset(finance_event, attrs) do
    finance_event
    |> cast(attrs, [
      :company_id,
      :token_usage_id,
      :event_type,
      :amount_usd,
      :currency,
      :description,
      :metadata
    ])
    |> validate_required([:company_id, :event_type, :amount_usd])
    |> validate_inclusion(:event_type, @event_types)
    |> validate_number(:amount_usd, greater_than_or_equal_to: 0)
    |> validate_length(:currency, min: 3, max: 3)
    |> foreign_key_constraint(:company_id)
    |> foreign_key_constraint(:token_usage_id)
  end

  def event_types, do: @event_types
end
