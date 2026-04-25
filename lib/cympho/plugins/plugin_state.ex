defmodule Cympho.Plugins.PluginState do
  @moduledoc """
  Plugin state schema - stores arbitrary key-value state for plugins.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "plugin_states" do
    field :key, :string
    field :value, :binary

    belongs_to :plugin, Cympho.Plugins.Plugin
    belongs_to :company, Cympho.Companies.Company

    timestamps(type: :utc_datetime)
  end

  def changeset(plugin_state, attrs) do
    plugin_state
    |> cast(attrs, [:key, :value, :plugin_id, :company_id])
    |> validate_required([:key, :value, :plugin_id, :company_id])
    |> unique_constraint([:plugin_id, :key])
    |> assoc_constraint(:plugin)
    |> assoc_constraint(:company)
  end
end
