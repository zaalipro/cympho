defmodule Cympho.ToolCallTraces.ToolCallTrace do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "tool_call_traces" do
    field :trace_type, :string
    field :tool_name, :string
    field :tool_arguments, :map, default: %{}
    field :tool_result, :string
    field :error_message, :string
    field :status, :string, default: "pending"

    field :content_hash, :string
    field :prev_hash, :string
    field :chain_hash, :string

    field :sequence_number, :integer
    field :occurred_at, :utc_datetime

    field :actor_type, :string, default: "agent"
    field :actor_id, :binary_id

    belongs_to :agent, Cympho.Agents.Agent
    belongs_to :issue, Cympho.Issues.Issue
    belongs_to :company, Cympho.Companies.Company

    timestamps(type: :utc_datetime)
  end

  def changeset(tool_call_trace, attrs) do
    tool_call_trace
    |> cast(attrs, [
      :trace_type,
      :tool_name,
      :tool_arguments,
      :tool_result,
      :error_message,
      :status,
      :content_hash,
      :prev_hash,
      :chain_hash,
      :sequence_number,
      :occurred_at,
      :agent_id,
      :issue_id,
      :company_id,
      :actor_type,
      :actor_id
    ])
    |> validate_required([
      :trace_type,
      :tool_name,
      :tool_arguments,
      :status,
      :content_hash,
      :chain_hash,
      :sequence_number,
      :occurred_at,
      :company_id,
      :actor_type
    ])
    |> validate_inclusion(:status, ["pending", "success", "error", "timeout"])
    |> validate_inclusion(:actor_type, ["user", "agent", "system"])
    |> validate_format(:content_hash, ~r/^[a-f0-9]{64}$/)
    |> validate_format(:chain_hash, ~r/^[a-f0-9]{64}$/)
    |> validate_prev_hash_format()
    |> assoc_constraint(:agent)
    |> assoc_constraint(:issue)
    |> assoc_constraint(:company)
    |> unique_constraint([:company_id, :sequence_number])
    |> unique_constraint(:content_hash)
  end

  def creation_changeset(attrs, prev_chain_hash \\ nil) do
    attrs =
      Map.put(
        attrs,
        :occurred_at,
        attrs[:occurred_at] || DateTime.utc_now() |> DateTime.truncate(:second)
      )

    {content_hash, _} = calculate_content_hash(attrs)

    final_attrs =
      attrs
      |> Map.put(:content_hash, content_hash)
      |> Map.put(:prev_hash, prev_chain_hash)
      |> then(fn attrs ->
        chain_hash = calculate_chain_hash(attrs[:content_hash], attrs[:prev_hash])
        Map.put(attrs, :chain_hash, chain_hash)
      end)

    changeset(%__MODULE__{}, final_attrs)
  end

  def calculate_content_hash(attrs) do
    content = %{
      trace_type: Map.get(attrs, :trace_type) || Map.get(attrs, "trace_type"),
      tool_name: Map.get(attrs, :tool_name) || Map.get(attrs, "tool_name"),
      tool_arguments: Map.get(attrs, :tool_arguments) || Map.get(attrs, "tool_arguments"),
      tool_result: Map.get(attrs, :tool_result) || Map.get(attrs, "tool_result"),
      error_message: Map.get(attrs, :error_message) || Map.get(attrs, "error_message"),
      status: Map.get(attrs, :status) || Map.get(attrs, "status"),
      occurred_at: Map.get(attrs, :occurred_at) || Map.get(attrs, "occurred_at"),
      actor_type: Map.get(attrs, :actor_type) || Map.get(attrs, "actor_type"),
      actor_id: Map.get(attrs, :actor_id) || Map.get(attrs, "actor_id")
    }

    hash =
      :crypto.hash(:sha256, :erlang.term_to_binary(content))
      |> Base.encode16(case: :lower)

    {hash, content}
  end

  def calculate_chain_hash(content_hash, prev_hash) do
    chain_input = "#{content_hash}#{prev_hash || ""}"

    hash =
      :crypto.hash(:sha256, chain_input)
      |> Base.encode16(case: :lower)

    hash
  end

  defp validate_prev_hash_format(changeset) do
    case get_change(changeset, :prev_hash) do
      nil ->
        changeset

      prev_hash when is_binary(prev_hash) ->
        if String.match?(prev_hash, ~r/^[a-f0-9]{64}$/) do
          changeset
        else
          add_error(changeset, :prev_hash, "invalid hash format")
        end

      _ ->
        changeset
    end
  end
end
