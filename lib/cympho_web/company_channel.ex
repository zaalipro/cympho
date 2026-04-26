defmodule CymphoWeb.CompanyChannel do
  @moduledoc """
  Company-level WebSocket channel.

  Handles scoped topic subscriptions (`company:<id>:<resource>`) with
  per-socket rate limiting (10 events/sec), heartbeat throttling (1/sec),
  and IP-based join rate limiting (10 joins/sec).
  """

  use CymphoWeb, :channel

  alias CymphoWeb.RateLimiter

  @impl true
  def join("company:" <> rest, payload, socket) do
    case RateLimiter.check_join(client_ip(socket)) do
      :ok ->
        join_topic(rest, payload, socket)

      {:error, :rate_limited} ->
        {:error, %{reason: "rate_limited"}}
    end
  end

  @impl true
  def join(_, _payload, _socket) do
    {:error, %{reason: "invalid_topic"}}
  end

  defp join_topic(rest, payload, socket) do
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
  def handle_info(:after_join, socket) do
    socket = maybe_replay_events(socket)
    {:noreply, socket}
  end

  @impl true
  def handle_in("ping", _payload, socket) do
    {:reply, {:ok, %{pong: true}}, socket}
  end

  @impl true
  def handle_in("heartbeat", _payload, socket) do
    case RateLimiter.check_heartbeat(socket_id(socket)) do
      :ok ->
        {:reply, {:ok, %{ts: System.system_time(:millisecond)}}, socket}

      {:error, :rate_limited} ->
        {:reply, {:error, %{reason: "rate_limited"}}, socket}
    end
  end

  @impl true
  def handle_in(event, payload, socket) do
    case RateLimiter.check_push(socket_id(socket)) do
      :ok ->
        {:noreply, socket}

      {:error, :rate_limited} ->
        {:reply, {:error, %{reason: "rate_limited"}}, socket}
    end
  end

  @impl true
  def terminate(_reason, socket) do
    RateLimiter.cleanup_socket(socket_id(socket))
    :ok
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
>>>>>>> origin/LLM-106c/event-replay
end
