defmodule CymphoWeb.HeartbeatsChannel do
  use CymphoWeb, :channel
  require Logger

  @impl true
  def join("company:" <> rest, _payload, socket) do
    case String.split(rest, ":", parts: 3) do
      [company_id, "issues", _issue_id] ->
        if socket.assigns.company_id == company_id do
          send(self(), :after_join)
          {:ok, socket}
        else
          {:error, %{reason: "unauthorized"}}
        end

      _ ->
        {:error, %{reason: "invalid_topic"}}
    end
  end

  @impl true
  def join(_, _payload, _socket) do
    {:error, %{reason: "invalid_topic"}}
  end

  @impl true
  def handle_info(:after_join, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_in("ping", _payload, socket) do
    {:reply, {:ok, %{pong: true}}, socket}
  end

  @impl true
  def handle_in("heartbeat", payload, socket) do
    broadcast(socket, "heartbeat", payload)
    {:noreply, socket}
  end
end
