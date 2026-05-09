defmodule CymphoWeb.AdapterLive.Show do
  use CymphoWeb, :live_view

  alias Cympho.Adapters
  alias Cympho.Agents

  @impl true
  def mount(%{"key" => key_str}, _session, socket) do
    key = String.to_existing_atom(key_str)

    case Adapters.get_adapter(key) do
      {:ok, adapter} ->
        health = Adapters.check_health(key, %{})

        agents =
          case socket.assigns[:current_company] do
            %{id: company_id} -> Agents.list_agents_by_adapter(key, company_id)
            _ -> []
          end

        config =
          agents
          |> Enum.find(fn agent -> agent.adapter == key end)
          |> case do
            nil -> default_config(adapter.config_schema)
            agent -> Map.merge(default_config(adapter.config_schema), agent.config || %{})
          end

        socket =
          socket
          |> assign(:page_title, adapter.name)
          |> assign(:adapter, adapter)
          |> assign(:adapter_key, key)
          |> assign(:health, health)
          |> assign(:agents, agents)
          |> assign(:config, config)
          |> assign(:config_schema, adapter.config_schema)
          |> assign(:validation_error, nil)
          |> assign(:test_result, nil)

        {:ok, socket}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Adapter not found")
         |> redirect(to: ~p"/adapters")}
    end
  rescue
    ArgumentError ->
      {:ok,
       socket
       |> put_flash(:error, "Invalid adapter key")
       |> redirect(to: ~p"/adapters")}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("test_health", _params, socket) do
    result = Adapters.check_health(socket.assigns.adapter_key, %{})
    {:noreply, assign(socket, health: result)}
  end

  @impl true
  def handle_event("send_test_heartbeat", _params, socket) do
    key = socket.assigns.adapter_key
    result = Adapters.check_health(key, %{})

    message =
      case result.status do
        :healthy -> "Test heartbeat succeeded: #{result.message || "OK"}"
        status -> "Test heartbeat returned #{status}: #{result.message || "no details"}"
      end

    {:noreply,
     socket
     |> assign(:health, result)
     |> assign(:test_result, result)
     |> put_flash(:info, message)}
  end

  @impl true
  def handle_event("validate_config", %{"config" => config_params}, socket) do
    config = normalize_config_keys(config_params, socket.assigns.config_schema)

    case Adapters.validate_config(socket.assigns.adapter_key, config) do
      :ok ->
        {:noreply, assign(socket, config: config, validation_error: nil)}

      {:error, reason} ->
        {:noreply, assign(socket, config: config, validation_error: reason)}
    end
  end

  @impl true
  def handle_event("save_config", %{"config" => config_params}, socket) do
    config = normalize_config_keys(config_params, socket.assigns.config_schema)

    case Adapters.validate_config(socket.assigns.adapter_key, config) do
      :ok ->
        agents = socket.assigns.agents

        Enum.each(agents, fn agent ->
          Agents.update_agent(agent, %{config: config})
        end)

        {:noreply,
         socket
         |> assign(:config, config)
         |> put_flash(:info, "Configuration saved for #{length(agents)} agent(s)")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:config, config)
         |> assign(:validation_error, reason)
         |> put_flash(:error, "Validation failed: #{reason}")}
    end
  end

  defp default_config(schema) do
    schema
    |> Enum.into(%{}, fn entry ->
      {entry.key, Map.get(entry, :default)}
    end)
  end

  defp normalize_config_keys(params, schema) when is_map(params) do
    allowed_keys =
      Map.new(schema, fn entry ->
        {Atom.to_string(entry.key), entry.key}
      end)

    params
    |> Enum.flat_map(fn {k, v} ->
      case Map.fetch(allowed_keys, to_string(k)) do
        {:ok, key} -> [{key, parse_config_value(v)}]
        :error -> []
      end
    end)
    |> Map.new()
  end

  defp parse_config_value(""), do: nil
  defp parse_config_value(v), do: v

  defp health_status_class(:healthy), do: "bg-success/20 text-success"
  defp health_status_class(:degraded), do: "bg-amber-500/20 text-amber-400"
  defp health_status_class(:unhealthy), do: "bg-red-500/20 text-red-400"
  defp health_status_class(_), do: "bg-text-quaternary/20 text-text-quaternary"

  defp health_status_label(:healthy), do: "Healthy"
  defp health_status_label(:degraded), do: "Degraded"
  defp health_status_label(:unhealthy), do: "Unhealthy"
  defp health_status_label(_), do: "Unknown"

  defp schema_type_label(:string), do: "Text"
  defp schema_type_label(:integer), do: "Number"
  defp schema_type_label(:boolean), do: "Toggle"
  defp schema_type_label(:float), do: "Decimal"
  defp schema_type_label(:map), do: "JSON"
  defp schema_type_label(:list), do: "List"
  defp schema_type_label(_), do: "Text"

  defp format_datetime(nil), do: "Never"
  defp format_datetime(dt), do: CymphoWeb.Format.format_datetime(dt)

  defp input_type(:integer), do: "number"
  defp input_type(:boolean), do: "checkbox"
  defp input_type(:float), do: "number"
  defp input_type(_), do: "text"
end
