defmodule CymphoWeb.CompanyChannel do
  use CymphoWeb, :channel

  @impl true
  def join("company:" <> rest, payload, socket) do
    case String.split(rest, ":", parts: 2) do
      [company_id] ->
        if socket.assigns.company_id == company_id do
          socket = maybe_assign_last_event_id(socket, payload)
          send(self(), :after_join)
          {:ok, socket}
        else
          {:error, %{reason: "unauthorized"}}
        end

      [company_id, sub_topic] ->
        if socket.assigns.company_id == company_id do
          dispatch_sub_topic("company:#{rest}", sub_topic, payload, socket)
        else
          {:error, %{reason: "unauthorized"}}
        end
    end
  end

  @impl true
  def join(_, _payload, _socket) do
    {:error, %{reason: "invalid_topic"}}
  end

  @impl true
  def handle_info(:after_join, socket) do
    socket = maybe_replay_events(socket)
    {:noreply, socket}
  end

  @impl true
  def handle_in("ping", _payload, socket) do
    {:reply, {:ok, %{pong: true}}, socket}
  end

  @impl true
  def handle_in(event, payload, socket) do
    {:noreply, socket}
  end

  defp dispatch_sub_topic(topic, "activities", _payload, socket) do
    CymphoWeb.ActivityChannel.join(topic, %{}, socket)
  end

  defp dispatch_sub_topic(topic, "issues", _payload, socket) do
    CymphoWeb.IssuesChannel.join(topic, %{}, socket)
  end

  defp dispatch_sub_topic(topic, "issue:" <> _issue_id, _payload, socket) do
    CymphoWeb.IssueChannel.join(topic, %{}, socket)
  end

  defp dispatch_sub_topic(topic, "project:" <> _project_id, _payload, socket) do
    CymphoWeb.CommentsChannel.join(topic, %{}, socket)
  end

  defp dispatch_sub_topic(_topic, _sub, _payload, _socket) do
    {:error, %{reason: "invalid_topic"}}
  end

  defp maybe_assign_last_event_id(socket, %{"last_event_id" => id}) when is_integer(id) do
    Phoenix.Socket.assign(socket, :last_event_id, id)
  end

  defp maybe_assign_last_event_id(socket, _payload), do: socket

  defp maybe_replay_events(%{assigns: %{last_event_id: last_id}} = socket) do
    case Cympho.EventStore.fetch_since(socket.topic, last_id) do
      {:ok, events} ->
        for event <- events, do: push(socket, "replay", event)
        socket

      {:error, :replay_window_expired} ->
        push(socket, "replay_expired", %{reason: "replay_window_expired"})
        socket
    end
  end

  defp maybe_replay_events(socket), do: socket
end
