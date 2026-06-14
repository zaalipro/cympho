defmodule CymphoWeb.PluginLive.FormHelpers do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]

  alias Cympho.Projects

  @default_entrypoint "Cympho.Plugins.CustomPlugin"

  def default_plugin(company_id) do
    %Cympho.Skills.Plugin{
      company_id: company_id,
      version: "0.1.0",
      status: "installed",
      enabled: true,
      manifest: default_manifest(),
      settings: %{},
      capabilities: []
    }
  end

  def assign_context_options(socket) do
    company_id = current_company_id(socket)

    assign(socket, :project_options, project_options(company_id))
  end

  def normalize_plugin_params(socket, params, opts \\ []) do
    company_id = current_company_id(socket)

    with :ok <- validate_project_ref(company_id, params["project_id"]) do
      capabilities = split_capabilities(params["capabilities"])
      base_manifest = base_manifest(opts[:plugin], params["manifest_json"])

      params =
        params
        |> Map.drop(["entrypoint", "capabilities", "manifest_json", "settings_json"])
        |> maybe_put_company_scope(company_id, Keyword.get(opts, :put_company_scope))
        |> Map.put("manifest", build_manifest(base_manifest, params, capabilities))
        |> Map.put("settings", decode_json(params["settings_json"], %{}))
        |> Map.put("capabilities", capabilities)

      {:ok, params}
    end
  end

  def manifest_entrypoint(%{manifest: manifest}), do: manifest_entrypoint(manifest)

  def manifest_entrypoint(manifest) when is_map(manifest) do
    Map.get(manifest, "entrypoint") || Map.get(manifest, :entrypoint) || @default_entrypoint
  end

  def manifest_entrypoint(_manifest), do: @default_entrypoint

  def capabilities_value(%{capabilities: capabilities}), do: capabilities_value(capabilities)

  def capabilities_value(capabilities) when is_list(capabilities),
    do: Enum.join(capabilities, ", ")

  def capabilities_value(_capabilities), do: ""

  def json_value(value) when is_map(value), do: Jason.encode!(value, pretty: true)
  def json_value(_value), do: "{}"

  defp default_manifest do
    %{
      "entrypoint" => @default_entrypoint,
      "capabilities" => [],
      "host_services" => []
    }
  end

  defp base_manifest(plugin, manifest_json) do
    plugin
    |> existing_manifest()
    |> Map.merge(decode_json(manifest_json, %{}))
  end

  defp build_manifest(base_manifest, params, capabilities) do
    base_manifest
    |> Map.put(
      "name",
      fallback(params["name"], Map.get(base_manifest, "name") || "Untitled Plugin")
    )
    |> Map.put(
      "version",
      fallback(params["version"], Map.get(base_manifest, "version") || "0.1.0")
    )
    |> Map.put(
      "author",
      fallback(params["author"], Map.get(base_manifest, "author") || "Cympho Labs")
    )
    |> Map.put(
      "entrypoint",
      fallback(params["entrypoint"], Map.get(base_manifest, "entrypoint") || @default_entrypoint)
    )
    |> Map.put("capabilities", capabilities)
    |> Map.put_new("host_services", [])
  end

  defp existing_manifest(%{manifest: manifest}) when is_map(manifest),
    do: stringify_keys(manifest)

  defp existing_manifest(_plugin), do: default_manifest()

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp decode_json(nil, default), do: default
  defp decode_json("", default), do: default

  defp decode_json(value, default) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) -> stringify_keys(decoded)
      _ -> default
    end
  end

  defp decode_json(value, _default) when is_map(value), do: stringify_keys(value)
  defp decode_json(_value, default), do: default

  defp split_capabilities(nil), do: []

  defp split_capabilities(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp split_capabilities(value) when is_list(value), do: value
  defp split_capabilities(_value), do: []

  defp fallback(value, default) when value in [nil, ""], do: default
  defp fallback(value, _default), do: value

  defp project_options(nil), do: [{"Company-wide plugin", ""}]

  defp project_options(company_id) do
    options =
      company_id
      |> Projects.list_projects_by_company()
      |> Enum.reject(&(&1.status == :archived))
      |> Enum.map(&{&1.name, &1.id})

    [{"Company-wide plugin", ""} | options]
  end

  defp validate_project_ref(_company_id, nil), do: :ok
  defp validate_project_ref(_company_id, ""), do: :ok

  defp validate_project_ref(company_id, project_id) when is_binary(company_id) do
    case Projects.get_company_project(company_id, project_id) do
      {:ok, _project} -> :ok
      {:error, _reason} -> {:error, :not_found}
    end
  end

  defp validate_project_ref(_company_id, _project_id), do: {:error, :not_found}

  defp maybe_put_company_scope(params, nil, _put_scope?), do: params
  defp maybe_put_company_scope(params, _company_id, false), do: params

  defp maybe_put_company_scope(params, company_id, _put_scope?),
    do: Map.put(params, "company_id", company_id)

  defp current_company_id(%{assigns: %{current_company: %{id: id}}}), do: id
  defp current_company_id(_socket), do: nil
end
