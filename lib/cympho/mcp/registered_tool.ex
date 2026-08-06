defmodule Cympho.Mcp.RegisteredTool do
  @moduledoc """
  Schema for a company-scoped dynamically registered MCP tool.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Cympho.Companies.Company

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(active unregistered)

  schema "mcp_registered_tools" do
    field :name, :string
    field :description, :string
    field :input_schema, :map, default: %{}
    field :plugin_id, :binary_id
    field :status, :string, default: "active"
    field :metadata, :map, default: %{}

    belongs_to :company, Company

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses

  def changeset(tool, attrs) do
    tool
    |> cast(attrs, [
      :company_id,
      :name,
      :description,
      :input_schema,
      :plugin_id,
      :status,
      :metadata
    ])
    |> validate_required([:company_id, :name, :status])
    |> update_change(:name, &normalize_name/1)
    |> validate_length(:name, min: 1, max: 128)
    |> validate_format(:name, ~r/^[a-z][a-z0-9_]*$/,
      message: "must be snake_case starting with a letter"
    )
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:company_id, :name],
      name: :mcp_registered_tools_company_name_active_idx
    )
    |> foreign_key_constraint(:company_id)
  end

  def unregister_changeset(tool) do
    change(tool, %{status: "unregistered"})
  end

  defp normalize_name(nil), do: nil

  defp normalize_name(name) when is_binary(name) do
    name
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_name(name), do: name
end
