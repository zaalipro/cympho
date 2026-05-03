defmodule Cympho.Companies.Company do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "companies" do
    field :name, :string
    field :slug, :string
    field :description, :string
    field :status, :string, default: "active"
    field :paused_at, :utc_datetime
    field :paused_reason, :string
    field :issue_prefix, :string, default: "CYM"
    field :issue_counter, :integer, default: 0
    field :budget_monthly_cents, :integer, default: 0
    field :spent_monthly_cents, :integer, default: 0
    field :attachment_max_bytes, :integer, default: 25_000_000
    field :require_board_approval_for_new_agents, :boolean, default: false
    field :brand_color, :string, default: "#5e6ad2"
    field :logo_url, :string
    field :governance_config, :map, default: %{}

    has_many :memberships, Cympho.Companies.CompanyMembership
    has_many :users, through: [:memberships, :user]
    has_many :projects, Cympho.Projects.Project
    has_many :agents, Cympho.Agents.Agent
    has_many :invites, Cympho.Companies.CompanyInvite
    has_many :join_requests, Cympho.Companies.JoinRequest

    timestamps(type: :utc_datetime)
  end

  def changeset(company, attrs) do
    company
    |> cast(attrs, [
      :name,
      :slug,
      :description,
      :status,
      :paused_at,
      :paused_reason,
      :issue_prefix,
      :issue_counter,
      :budget_monthly_cents,
      :spent_monthly_cents,
      :attachment_max_bytes,
      :require_board_approval_for_new_agents,
      :brand_color,
      :logo_url,
      :governance_config
    ])
    |> validate_required([:name, :slug])
    |> validate_format(:slug, ~r/^[a-z0-9-]+$/,
      message: "must contain only lowercase letters, numbers, and hyphens"
    )
    |> validate_length(:slug, min: 3, max: 50)
    |> validate_inclusion(:status, ~w(active paused archived))
    |> validate_length(:issue_prefix, min: 2, max: 10)
    |> validate_format(:issue_prefix, ~r/^[A-Z][A-Z0-9]*$/,
      message: "must be uppercase letters or numbers"
    )
    |> validate_number(:issue_counter, greater_than_or_equal_to: 0)
    |> validate_number(:budget_monthly_cents, greater_than_or_equal_to: 0)
    |> validate_number(:spent_monthly_cents, greater_than_or_equal_to: 0)
    |> validate_number(:attachment_max_bytes, greater_than: 0)
    |> validate_format(:brand_color, ~r/^#[0-9a-fA-F]{6}$/,
      message: "must be a six digit hex color"
    )
    |> unique_constraint(:slug)
    |> validate_logo_url()
    |> validate_governance_config()
  end

  defp validate_logo_url(changeset) do
    case get_change(changeset, :logo_url) do
      nil ->
        changeset

      "" ->
        changeset

      _url ->
        validate_format(changeset, :logo_url, ~r/^https?:\/\/.+/, message: "must be a valid URL")
    end
  end

  defp validate_governance_config(changeset) do
    case get_change(changeset, :governance_config) do
      nil ->
        changeset

      config when is_map(config) ->
        categories = Map.get(config, "categories")
        threshold_type = Map.get(config, "threshold_type")
        threshold_value = Map.get(config, "threshold_value")

        cond do
          not is_nil(categories) and not is_list(categories) ->
            add_error(changeset, :governance_config, "categories must be a list")

          threshold_type not in [nil, "any", "percentage", "count", "all"] ->
            add_error(
              changeset,
              :governance_config,
              "threshold_type must be any, percentage, count, or all"
            )

          not is_nil(threshold_value) and not is_number(threshold_value) ->
            add_error(changeset, :governance_config, "threshold_value must be a number")

          true ->
            changeset
        end

      _ ->
        add_error(changeset, :governance_config, "must be a map")
    end
  end
end
