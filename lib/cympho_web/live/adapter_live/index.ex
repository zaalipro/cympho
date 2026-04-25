defmodule CymphoWeb.AdapterLive.Index do
  use CymphoWeb, :live_view

  alias Cympho.Adapters
  alias Cympho.Agents

  @impl true
  def mount(_params, _session, socket) do
    adapters = Adapters.list_adapters()
    health = Adapters.check_all_health()

    agents_by_adapter =
      Agents.adapter_options()
      |> Enum.into(%{}, fn key ->
        {key, Agents.list_agents_by_adapter(key)}
      end)

    socket =
      socket
      |> assign(:page_title, "Adapters")
      |> assign(:adapters, adapters)
      |> assign(:health, health)
      |> assign(:agents_by_adapter, agents_by_adapter)

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("refresh_health", _params, socket) do
    health = Adapters.check_all_health()
    {:noreply, assign(socket, :health, health)}
  end

  @impl true
  def handle_event("test_adapter", %{"key" => key}, socket) do
    key_atom = String.to_existing_atom(key)
    result = Adapters.check_health(key_atom, %{})

    health = Map.put(socket.assigns.health, key_atom, result)

    message =
      case result.status do
        :healthy -> "#{adapter_name(socket, key_atom)} health check passed"
        :degraded -> "#{adapter_name(socket, key_atom)} is degraded: #{result.message}"
        :unhealthy -> "#{adapter_name(socket, key_atom)} is unhealthy: #{result.message}"
        :unknown -> "#{adapter_name(socket, key_atom)} status unknown"
      end

    {:noreply,
     socket
     |> assign(:health, health)
     |> put_flash(:info, message)}
  end

  defp adapter_name(socket, key) do
    case Enum.find(socket.assigns.adapters, fn a -> a.key == key end) do
      nil -> Atom.to_string(key)
      adapter -> adapter.name
    end
  end

  defp health_status_class(:healthy), do: "bg-success/20 text-success"
  defp health_status_class(:degraded), do: "bg-amber-500/20 text-amber-400"
  defp health_status_class(:unhealthy), do: "bg-red-500/20 text-red-400"
  defp health_status_class(_), do: "bg-text-quaternary/20 text-text-quaternary"

  defp health_status_label(:healthy), do: "Healthy"
  defp health_status_label(:degraded), do: "Degraded"
  defp health_status_label(:unhealthy), do: "Unhealthy"
  defp health_status_label(_), do: "Unknown"

  defp availability_class(true), do: "text-success"
  defp availability_class(false), do: "text-red-400"

  defp availability_label(true), do: "Available"
  defp availability_label(false), do: "Unavailable"

  defp adapter_icon(:claude_code), do: "⚡"
  defp adapter_icon(:codex), do: "🔬"
  defp adapter_icon(:cursor), do: "🖱"
  defp adapter_icon(:http), do: "🌐"
  defp adapter_icon(:openclaw), do: "🐾"
  defp adapter_icon(:process), do: "⚙"
  defp adapter_icon(_), do: "📦"

  defp agent_count(socket, key) do
    length(Map.get(socket.assigns.agents_by_adapter, key, []))
  end
end
