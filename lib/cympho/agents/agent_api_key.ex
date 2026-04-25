defmodule Cympho.Agents.AgentApiKey do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "agent_api_keys" do
    field :name, :string
    field :key_hash, :string
    field :last_used_at, :utc_datetime
    field :expires_at, :utc_datetime

    belongs_to :agent, Cympho.Agents.Agent

    timestamps(type: :utc_datetime)
  end

  def changeset(api_key, attrs) do
    api_key
    |> cast(attrs, [:name, :key_hash, :agent_id, :expires_at])
    |> validate_required([:name, :key_hash, :agent_id])
    |> validate_length(:name, min: 1, max: 255)
    |> assoc_constraint(:agent)
  end

  def generate_api_key do
    :crypto.strong_rand_bytes(32)
    |> Base.encode64()
    |> URI.encode()
  end

  def hash_api_key(api_key) do
    :crypto.hash(:sha256, api_key)
    |> Base.encode16(case: :lower)
  end

  def valid_api_key?(api_key, key_hash) do
    hash_api_key(api_key) == key_hash
  end
end
