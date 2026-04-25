defmodule Cympho.Finances.TokenUsage do
  use Ecto.Schema
  import Ecto.Changeset

  alias Cympho.Companies.Company
  alias Cympho.Agents.Agent
  alias Cympho.Projects.Project
  alias Cympho.Goals.Goal
  alias Cympho.Issues.Issue

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "token_usages" do
    belongs_to :company, Company
    belongs_to :agent, Agent
    belongs_to :project, Project
    belongs_to :goal, Goal
    belongs_to :issue, Issue

    field :provider, :string
    field :model, :string

    field :input_tokens, :integer, default: 0
    field :output_tokens, :integer, default: 0
    field :total_tokens, :integer, default: 0

    field :cost_usd, :decimal, default: Decimal.new("0.0")

    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  def changeset(token_usage, attrs) do
    token_usage
    |> cast(attrs, [
      :company_id,
      :agent_id,
      :project_id,
      :goal_id,
      :issue_id,
      :provider,
      :model,
      :input_tokens,
      :output_tokens,
      :total_tokens,
      :cost_usd,
      :metadata
    ])
    |> validate_required([:company_id, :provider, :model])
    |> validate_number(:input_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:output_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:total_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:cost_usd, greater_than_or_equal_to: 0)
    |> compute_total_tokens()
    |> foreign_key_constraint(:company_id)
    |> foreign_key_constraint(:agent_id)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:goal_id)
    |> foreign_key_constraint(:issue_id)
  end

  defp compute_total_tokens(changeset) do
    case get_field(changeset, :total_tokens) do
      nil ->
        input = get_field(changeset, :input_tokens) || 0
        output = get_field(changeset, :output_tokens) || 0
        put_change(changeset, :total_tokens, input + output)

      _ ->
        changeset
    end
  end
end
