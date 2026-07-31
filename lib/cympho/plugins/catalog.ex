defmodule Cympho.Plugins.Catalog do
  @moduledoc """
  Validated, source-backed entries shown in the local plugin catalog.

  This catalog does not download code. Installable entries create the same
  company-scoped plugin records used by the existing plugin workflow.
  """

  @entries [
    %{
      identifier: "github-integration",
      name: "GitHub Integration",
      version: "1.0.0",
      description:
        "Built-in GitHub webhook subsystem reference. It is visible for capability discovery but is not a standalone plugin worker.",
      author: "Cympho",
      capabilities: ["read:issues", "write:issues"],
      installable?: false,
      source_module: CymphoWeb.GithubController,
      source_label: "Built-in subsystem"
    },
    %{
      identifier: "custom-webhook",
      name: "Custom Webhooks",
      version: "1.1.0",
      description:
        "Built-in webhook record subsystem reference. It is visible for capability discovery but is not a standalone plugin worker.",
      author: "Cympho",
      capabilities: ["webhook"],
      installable?: false,
      source_module: Cympho.Plugins.PluginWebhook,
      source_label: "Built-in subsystem"
    },
    %{
      identifier: "example-plugin",
      name: "Plugin SDK Example",
      version: "1.0.0",
      description:
        "Local supervised worker demonstrating the plugin lifecycle and company-scoped host services.",
      author: "Cympho",
      capabilities: ["read:issues"],
      installable?: true,
      source_module: Cympho.Plugins.ExamplePlugin,
      source_label: "Local worker"
    }
  ]

  @required_string_fields ~w(identifier name version description author source_label)a

  def entries do
    validate_entries!(@entries)
  end

  def fetch(identifier) when is_binary(identifier) do
    case Enum.find(entries(), &(&1.identifier == identifier)) do
      nil -> {:error, :not_found}
      entry -> {:ok, entry}
    end
  end

  def fetch(_identifier), do: {:error, :not_found}

  def validate_entry(entry) when is_map(entry) do
    with :ok <- validate_required_strings(entry),
         :ok <- validate_identifier(Map.get(entry, :identifier)),
         :ok <- validate_version(Map.get(entry, :version)),
         :ok <- validate_capabilities(Map.get(entry, :capabilities)),
         :ok <- validate_installability(Map.get(entry, :installable?)),
         :ok <-
           validate_source_module(
             Map.get(entry, :source_module),
             Map.get(entry, :installable?)
           ) do
      {:ok, entry}
    end
  end

  def validate_entry(_entry), do: {:error, :entry_must_be_a_map}

  def install_manifest(entry) do
    %{
      "name" => entry.name,
      "version" => entry.version,
      "author" => entry.author,
      "entrypoint" => inspect(entry.source_module),
      "capabilities" => entry.capabilities,
      "permissions" => [],
      "dependencies" => %{},
      "source" => "local_catalog"
    }
  end

  defp validate_entries!(entries) do
    validated =
      Enum.map(entries, fn entry ->
        case validate_entry(entry) do
          {:ok, valid_entry} -> valid_entry
          {:error, reason} -> raise "invalid local plugin catalog entry: #{inspect(reason)}"
        end
      end)

    identifiers = Enum.map(validated, & &1.identifier)

    if Enum.uniq(identifiers) == identifiers do
      validated
    else
      raise "local plugin catalog identifiers must be unique"
    end
  end

  defp validate_required_strings(entry) do
    if Enum.all?(@required_string_fields, fn key ->
         value = Map.get(entry, key)
         is_binary(value) and String.trim(value) != ""
       end) do
      :ok
    else
      {:error, :missing_required_string}
    end
  end

  defp validate_identifier(identifier) when is_binary(identifier) do
    if Regex.match?(~r/^[a-z0-9][a-z0-9-]*$/, identifier),
      do: :ok,
      else: {:error, :invalid_identifier}
  end

  defp validate_identifier(_identifier), do: {:error, :invalid_identifier}

  defp validate_version(version) when is_binary(version) do
    case Version.parse(version) do
      {:ok, _version} -> :ok
      :error -> {:error, :invalid_version}
    end
  end

  defp validate_version(_version), do: {:error, :invalid_version}

  defp validate_capabilities(capabilities)
       when is_list(capabilities) and capabilities != [] do
    if Enum.all?(capabilities, &(is_binary(&1) and String.trim(&1) != "")),
      do: :ok,
      else: {:error, :invalid_capabilities}
  end

  defp validate_capabilities(_capabilities), do: {:error, :invalid_capabilities}

  defp validate_installability(value) when is_boolean(value), do: :ok
  defp validate_installability(_value), do: {:error, :invalid_installability}

  defp validate_source_module(module, installable?) when is_atom(module) do
    cond do
      not Code.ensure_loaded?(module) ->
        {:error, :source_module_not_found}

      installable? and not function_exported?(module, :start_link, 1) ->
        {:error, :source_module_not_startable}

      true ->
        :ok
    end
  end

  defp validate_source_module(_module, _installable?), do: {:error, :invalid_source_module}
end
