defmodule CymphoWeb.IssueChannel do
  use CymphoWeb, :channel
  alias Cympho.Activities

  @impl true
  def join("issue:" <> _issue_id, _payload, socket) do
    send(self(), :after_join)
    {:ok, socket}
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
