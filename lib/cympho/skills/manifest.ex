defmodule Cympho.Skills.Manifest do
  @moduledoc """
  Skill manifest schema and validation.

  A skill manifest is a JSON/map structure that defines:
  - name: Human-readable skill name
  - version: Semver string (e.g., "1.0.0")
  - author: Author identifier
  - capabilities: List of capability strings
  - dependencies: Map of dependency name to version requirement
  - entrypoint: Module name for the skill entry point
  - permissions: List of required permissions
  """

  @type t :: %__MODULE__{
    name: String.t(),
    version: String.t(),
    author: String.t(),
    capabilities: [String.t()],
    dependencies: %{String.t() => String.t()},
    entrypoint: String.t(),
    permissions: [String.t()]
  }

  defstruct [
    :name,
    :version,
    :author,
    capabilities: [],
    dependencies: %{},
    entrypoint: nil,
    permissions: []
  ]

  @doc """
  Validates a manifest map against the schema.

  Returns {:ok, manifest} if valid, {:error, reasons} if invalid.
  """
  def validate(data) when is_map(data) do
    with {:ok, name} <- validate_required_field(data, "name", "string"),
         {:ok, version} <- validate_required_field(data, "version", "string") |> validate_semver(),
         {:ok, author} <- validate_required_field(data, "author", "string"),
         {:ok, capabilities} <- validate_field(data, "capabilities", "list", []),
         {:ok, dependencies} <- validate_field(data, "dependencies", "map", %{}),
         {:ok, entrypoint} <- validate_required_field(data, "entrypoint", "string"),
         {:ok, permissions} <- validate_field(data, "permissions", "list", []) do
      manifest = %__MODULE__{
        name: name,
        version: version,
        author: author,
        capabilities: capabilities,
        dependencies: dependencies,
        entrypoint: entrypoint,
        permissions: permissions
      }
      {:ok, manifest}
    else
      {:error, reason} -> {:error, [reason]}
    end
  end

  def validate(_), do: {:error, ["manifest must be a map"]}

  defp validate_required_field(data, key, type) do
    case Map.get(data, key) do
      nil -> {:error, "#{key} is required"}
      value -> validate_type(value, key, type)
    end
  end

  defp validate_field(data, key, type, default) do
    case Map.get(data, key, default) do
      value when is_nil(value) or value == default -> {:ok, default}
      value -> validate_type(value, key, type)
    end
  end

  defp validate_type(value, _key, "string") when is_binary(value), do: {:ok, value}
  defp validate_type(_, key, "string"), do: {:error, "#{key} must be a string"}

  defp validate_type(value, _key, "list") when is_list(value), do: {:ok, value}
  defp validate_type(_, key, "list"), do: {:error, "#{key} must be a list"}

  defp validate_type(value, _key, "map") when is_map(value), do: {:ok, value}
  defp validate_type(_, key, "map"), do: {:error, "#{key} must be a map"}

  defp validate_semver({:ok, version}), do: validate_semver(version)
  defp validate_semver({:error, _} = error), do: error
  defp validate_semver(version) when is_binary(version) do
    case Version.parse(version) do
      {:ok, _} -> {:ok, version}
      :error -> {:error, "version must be a valid semver string"}
    end
  end
end
