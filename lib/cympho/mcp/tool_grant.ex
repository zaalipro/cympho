defmodule Cympho.Mcp.ToolGrant do
  @moduledoc """
  Schema for per-agent (or company-wide) authorization of a dynamic MCP tool.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Cympho.Agents.Agent
  alias Cympho.Companies.Company
  alias Cympho.Mcp.RegisteredTool

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(allow deny pending revoked)

  schema "mcp_tool_grants" do
    field :tool_name, :string
    field :status, :string, default: "pending"
    field :reason, :string
    field :granted_by_type, :string
    field :granted_by_id, :string
    field :metadata, :map, default: %{}
    field :sequence, :integer, read_after_writes: true

    belongs_to :company, Company
    belongs_to :tool, RegisteredTool
    belongs_to :agent, Agent

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses

  def changeset(grant, attrs) do
    grant
    |> cast(attrs, [
      :company_id,
      :tool_id,
      :tool_name,
      :agent_id,
      :status,
      :reason,
      :granted_by_type,
      :granted_by_id,
      :metadata
    ])
    |> validate_required([:company_id, :tool_name, :status])
    |> update_change(:tool_name, &normalize_name/1)
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:company_id)
    |> foreign_key_constraint(:tool_id)
    |> foreign_key_constraint(:agent_id)
  end

  def revoke_changeset(grant, reason \\ nil) do
    attrs =
      if is_binary(reason) and reason != "" do
        %{status: "revoked", reason: reason}
      else
        %{status: "revoked"}
      end

    cast(grant, attrs, [:status, :reason])
  end

  defp normalize_name(nil), do: nil

  defp normalize_name(name) when is_binary(name) do
    name
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_name(name), do: name
end
