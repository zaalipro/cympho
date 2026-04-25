defmodule Cympho.Plugins.PluginLog do
  @moduledoc """
  Plugin log schema - stores log entries from plugin execution.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "plugin_logs" do
    field :level, :string, default: "info"
    field :message, :string
    field :metadata, :map, default: %{}
    field :timestamp, :utc_datetime

    belongs_to :plugin, Cympho.Plugins.Plugin
    belongs_to :company, Cympho.Companies.Company

    timestamps(type: :utc_datetime)
  end

  def changeset(plugin_log, attrs) do
    plugin_log
    |> cast(attrs, [:level, :message, :metadata, :timestamp, :plugin_id, :company_id])
    |> validate_required([:message, :timestamp, :plugin_id, :company_id])
    |> validate_inclusion(:level, ["debug", "info", "warn", "error"])
    |> assoc_constraint(:plugin)
    |> assoc_constraint(:company)
  end
end
