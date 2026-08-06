defmodule Cympho.Evaluations.EvaluationSuite do
  @moduledoc """
  Company-scoped deterministic evaluation suite definition.

  Suites hold fixture cases (or a prompt-contract role) that produce immutable
  runs. Cases are stored as a map with an `"items"` list so JSON encoding stays
  uniform across drivers.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Cympho.Companies.Company

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @kinds ~w(prompt_contract custom)

  schema "evaluation_suites" do
    field :name, :string
    field :identifier, :string
    field :description, :string
    field :kind, :string, default: "prompt_contract"
    field :role, :string
    field :cases, :map, default: %{}
    field :config, :map, default: %{}
    field :enabled, :boolean, default: true

    belongs_to :company, Company
    has_many :runs, Cympho.Evaluations.EvaluationRun, foreign_key: :suite_id

    timestamps(type: :utc_datetime)
  end

  def kinds, do: @kinds

  def changeset(suite, attrs) do
    attrs = coerce_cases_attr(attrs)

    suite
    |> cast(attrs, [
      :company_id,
      :name,
      :identifier,
      :description,
      :kind,
      :role,
      :cases,
      :config,
      :enabled
    ])
    |> validate_required([:company_id, :name, :identifier, :kind])
    |> validate_inclusion(:kind, @kinds)
    |> validate_length(:name, min: 1, max: 200)
    |> validate_length(:identifier, min: 1, max: 120)
    |> validate_format(:identifier, ~r/^[a-z0-9][a-z0-9_\-]*$/i,
      message: "must be alphanumeric with optional hyphens/underscores"
    )
    |> put_default_cases()
    |> normalize_cases()
    |> validate_role_for_kind()
    |> unique_constraint(:identifier,
      name: :evaluation_suites_company_id_identifier_index,
      message: "has already been taken"
    )
    |> assoc_constraint(:company)
  end

  defp coerce_cases_attr(attrs) when is_map(attrs) do
    cases = Map.get(attrs, :cases) || Map.get(attrs, "cases")

    cond do
      is_list(cases) ->
        attrs
        |> Map.delete("cases")
        |> Map.put(:cases, %{"items" => cases})

      true ->
        attrs
    end
  end

  defp coerce_cases_attr(attrs), do: attrs

  def case_items(%__MODULE__{cases: cases}), do: case_items(cases)

  def case_items(%{"items" => items}) when is_list(items), do: items
  def case_items(%{items: items}) when is_list(items), do: items
  def case_items(items) when is_list(items), do: items
  def case_items(_), do: []

  defp put_default_cases(changeset) do
    case get_field(changeset, :cases) do
      nil -> put_change(changeset, :cases, %{"items" => []})
      %{} = map when map_size(map) == 0 -> put_change(changeset, :cases, %{"items" => []})
      _ -> changeset
    end
  end

  defp normalize_cases(changeset) do
    case get_change(changeset, :cases) || get_field(changeset, :cases) do
      items when is_list(items) ->
        put_change(changeset, :cases, %{"items" => items})

      %{} = map ->
        items = case_items(map)
        put_change(changeset, :cases, Map.put(stringify_keys(map), "items", items))

      _ ->
        changeset
    end
  end

  defp validate_role_for_kind(changeset) do
    kind = get_field(changeset, :kind)
    role = get_field(changeset, :role)

    cond do
      kind == "prompt_contract" and (is_nil(role) or role == "") ->
        add_error(changeset, :role, "is required for prompt_contract suites")

      true ->
        changeset
    end
  end

  defp stringify_keys(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
