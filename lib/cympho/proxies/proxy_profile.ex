defmodule Cympho.Proxies.ProxyProfile do
  use Ecto.Schema
  import Ecto.Changeset

  alias Cympho.Companies.Company

  @proxy_types ~w(http https socks4 socks5)
  @derive {Inspect, except: [:encrypted_password, :password, :proxy_url]}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "proxy_profiles" do
    belongs_to :company, Company

    field :name, :string
    field :proxy_type, :string
    field :host, :string
    field :port, :integer
    field :username, :string
    field :encrypted_password, :binary
    field :password, :string, virtual: true
    field :proxy_url, :string, virtual: true
    field :description, :string
    field :is_active, :boolean, default: true
    field :last_status, :string, default: "untested"
    field :last_ping_ms, :integer
    field :last_checked_at, :utc_datetime
    field :last_error, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(proxy_profile, attrs) do
    proxy_profile
    |> cast(attrs, [
      :company_id,
      :name,
      :proxy_type,
      :host,
      :port,
      :username,
      :encrypted_password,
      :password,
      :proxy_url,
      :description,
      :is_active,
      :last_status,
      :last_ping_ms,
      :last_checked_at,
      :last_error
    ])
    |> validate_required([:company_id, :name, :proxy_type, :host, :port])
    |> validate_inclusion(:proxy_type, @proxy_types)
    |> validate_format(:name, ~r/^[^:\/?#]+$/, message: "must be a profile name, not a proxy URL")
    |> validate_length(:name, min: 1, max: 120)
    |> validate_length(:host, min: 1, max: 255)
    |> validate_number(:port, greater_than: 0, less_than: 65_536)
    |> validate_inclusion(:last_status, ~w(untested online offline))
    |> foreign_key_constraint(:company_id)
    |> unique_constraint(:name, name: :proxy_profiles_company_id_name_index)
  end

  def test_changeset(proxy_profile, attrs) do
    proxy_profile
    |> cast(attrs, [:last_status, :last_ping_ms, :last_checked_at, :last_error])
    |> validate_required([:last_status, :last_checked_at])
    |> validate_inclusion(:last_status, ~w(untested online offline))
  end

  def proxy_types, do: @proxy_types
end
