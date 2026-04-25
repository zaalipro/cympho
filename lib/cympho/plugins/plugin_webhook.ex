defmodule Cympho.Plugins.PluginWebhook do
  @moduledoc """
  Plugin webhook schema - stores webhook configurations for plugin events.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "plugin_webhooks" do
    field :event_type, :string
    field :url, :string
    field :secret, :string
    field :enabled, :boolean, default: true
    field :last_triggered_at, :utc_datetime
    field :failure_count, :integer, default: 0

    belongs_to :plugin, Cympho.Plugins.Plugin
    belongs_to :company, Cympho.Companies.Company

    timestamps(type: :utc_datetime)
  end

  def changeset(plugin_webhook, attrs) do
    plugin_webhook
    |> cast(attrs, [:event_type, :url, :secret, :enabled, :last_triggered_at, :failure_count, :plugin_id, :company_id])
    |> validate_required([:event_type, :url, :plugin_id, :company_id])
    |> validate_format(:url, ~r/^https?:\/\//)
    |> assoc_constraint(:plugin)
    |> assoc_constraint(:company)
  end
end
