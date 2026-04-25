defmodule CymphoWeb.CompanyChannel do
  use CymphoWeb, :channel

  @impl true
  def join("company:" <> topic, _payload, socket) do
    case parse_company_id(topic) do
      {:ok, company_id} ->
        if socket.assigns.company_id == company_id do
          send(self(), :after_join)
          {:ok, socket}
        else
          {:error, %{reason: "unauthorized"}}
        end

      :error ->
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

  defp parse_company_id(topic) do
    case String.split(topic, ":", parts: 2) do
      [company_id | _] ->
        if byte_size(company_id) > 0, do: {:ok, company_id}, else: :error

      _ ->
        :error
    end
  end
end
