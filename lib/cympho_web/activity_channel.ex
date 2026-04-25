defmodule CymphoWeb.ActivityChannel do
  use CymphoWeb, :channel

  @impl true
  def join("company:" <> rest, _payload, socket) do
    case String.split(rest, ":", parts: 2) do
      [company_id, "activities"] ->
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
  def handle_info(:after_join, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_in("ping", _payload, socket) do
    {:reply, {:ok, %{pong: true}}, socket}
  end
end
