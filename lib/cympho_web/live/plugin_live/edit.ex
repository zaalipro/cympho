defmodule CymphoWeb.PluginLive.Edit do
  use CymphoWeb, :live_view

  alias Cympho.Plugins
  alias Cympho.Repo

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case fetch_company_plugin(socket, id) do
      {:ok, plugin} ->
        plugin = Repo.preload(plugin, [:company, :project])
        changeset = Plugins.change_plugin(plugin)

        {:ok,
         socket
         |> assign(:page_title, "Edit #{plugin.name}")
         |> assign(:plugin, plugin)
         |> assign_form(changeset)}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Plugin not found")
         |> push_navigate(to: ~p"/plugins")}
    end
  end

  defp fetch_company_plugin(socket, id) do
    case socket.assigns[:current_company] do
      %{id: company_id} -> Plugins.get_company_plugin(company_id, id)
      _ -> {:error, :not_found}
    end
  end

  @impl true
  def handle_event("save", %{"plugin" => plugin_params}, socket) do
    case Plugins.update_plugin(socket.assigns.plugin, normalize_plugin_params(plugin_params)) do
      {:ok, plugin} ->
        {:noreply,
         socket
         |> put_flash(:info, "Plugin updated successfully")
         |> push_navigate(to: ~p"/plugins/#{plugin.id}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  def handle_event("validate", %{"plugin" => plugin_params}, socket) do
    changeset =
      socket.assigns.plugin
      |> Plugins.change_plugin(normalize_plugin_params(plugin_params))
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, :form, to_form(changeset))
  end

  defp normalize_plugin_params(params) do
    params
    |> Map.drop(["manifest_json", "settings_json"])
    |> Map.put("manifest", decode_json(params["manifest_json"], %{}))
    |> Map.put("settings", decode_json(params["settings_json"], %{}))
    |> Map.put("capabilities", split_capabilities(params["capabilities"]))
  end

  defp decode_json(nil, default), do: default
  defp decode_json("", default), do: default

  defp decode_json(value, default) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> default
    end
  end

  defp decode_json(value, _default) when is_map(value), do: value
  defp decode_json(_, default), do: default

  defp split_capabilities(nil), do: []

  defp split_capabilities(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp split_capabilities(value) when is_list(value), do: value
  defp split_capabilities(_), do: []

  def json_value(value) when is_map(value), do: Jason.encode!(value, pretty: true)
  def json_value(_), do: "{}"

  def capabilities_value(value) when is_list(value), do: Enum.join(value, ", ")
  def capabilities_value(_), do: ""
end
