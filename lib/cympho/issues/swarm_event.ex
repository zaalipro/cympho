defmodule Cympho.Issues.SwarmEvent do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "swarm_events" do
    field :event_type, :string
    field :status, :string, default: "info"
    field :message, :string
    field :metadata, :map, default: %{}
    field :occurred_at, :utc_datetime

    belongs_to :company, Cympho.Companies.Company
    belongs_to :parent_issue, Cympho.Issues.Issue
    belongs_to :issue, Cympho.Issues.Issue
    belongs_to :agent, Cympho.Agents.Agent

    timestamps(type: :utc_datetime)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :company_id,
      :parent_issue_id,
      :issue_id,
      :agent_id,
      :event_type,
      :status,
      :message,
      :metadata,
      :occurred_at
    ])
    |> validate_required([:company_id, :parent_issue_id, :event_type, :status, :message])
    |> validate_inclusion(:status, ["info", "success", "warning", "error"])
    |> validate_length(:event_type, min: 1, max: 80)
    |> validate_length(:message, min: 1, max: 2_000)
    |> put_default_occurred_at()
    |> assoc_constraint(:company)
    |> assoc_constraint(:parent_issue)
    |> assoc_constraint(:issue)
    |> assoc_constraint(:agent)
    |> prepare_changes(&validate_company_scope/1)
  end

  defp validate_company_scope(changeset) do
    company_id = get_field(changeset, :company_id)

    changeset
    |> validate_same_company(:parent_issue_id, Cympho.Issues.Issue, company_id)
    |> validate_same_company(:issue_id, Cympho.Issues.Issue, company_id)
    |> validate_same_company(:agent_id, Cympho.Agents.Agent, company_id)
  end

  defp validate_same_company(changeset, field, schema, company_id) do
    case get_field(changeset, field) do
      nil ->
        changeset

      id ->
        case changeset.repo.get(schema, id) do
          %{company_id: ^company_id} -> changeset
          nil -> changeset
          _record -> add_error(changeset, field, "must belong to the same company")
        end
    end
  end

  defp put_default_occurred_at(changeset) do
    case get_field(changeset, :occurred_at) do
      nil -> put_change(changeset, :occurred_at, DateTime.utc_now() |> DateTime.truncate(:second))
      _occurred_at -> changeset
    end
  end
end
