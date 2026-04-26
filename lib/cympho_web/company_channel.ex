defmodule CymphoWeb.CompanyChannel do
  @moduledoc """
  Main company channel handling WebSocket connections.

  ## Rate Limiting

  This channel enforces several rate limits to prevent abuse and flooding:

  - **Per-socket message rate limit:** Each connected socket is limited to
    10 events per second using a token bucket algorithm. Events exceeding
    this limit receive a `{:error, %{reason: "rate_limited"}}` reply.

  - **Heartbeat throttling:** Heartbeat events (`"heartbeat"` push) are
    limited to 1 per second per client. Excess heartbeats are rejected
    with a rate-limit error.

  - **IP-based join rate limit:** Channel joins are limited to 10 per second
    per IP address to prevent thundering herd attacks. Excess join attempts
    receive `{:error, %{reason: "rate_limited"}}`.
  """

  use CymphoWeb, :channel

  alias Cympho.RateLimiting

  @impl true
  def join("company:" <> rest, payload, socket) do
    ip = Map.get(socket.assigns, :ip_address, {127, 0, 0, 1})

    case Cympho.RateLimiting.IpRateLimiter.check_join(ip) do
      :ok ->
        do_join(rest, payload, socket)

      {:error, :rate_limited} ->
        {:error, %{reason: "rate_limited"}}
    end
  end

  @impl true
  def join(_, _payload, _socket) do
    {:error, %{reason: "invalid_topic"}}
  end

  defp do_join(rest, payload, socket) do
    case String.split(rest, ":", parts: 2) do
      [company_id] ->
        if socket.assigns.company_id == company_id do
          socket = assign_last_event_id(socket, payload)
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
    case RateLimiting.check_message_rate(socket) do
      {:ok, socket} ->
        {:reply, {:ok, %{pong: true}}, socket}

      {:error, :rate_limited} ->
        {:reply, {:error, %{reason: "rate_limited"}}, socket}
    end
  end

  # Phoenix serializes handle_in calls per socket process, so
  # check_heartbeat_throttle/1 does not need its own concurrency guard.
  @impl true
  def handle_in("heartbeat", payload, socket) do
    with {:ok, socket} <- RateLimiting.check_heartbeat_throttle(socket),
         {:ok, socket} <- RateLimiting.check_message_rate(socket) do
      broadcast(socket, "heartbeat", payload)
      {:reply, :ok, socket}
    else
      {:error, :rate_limited} ->
        {:reply, {:error, %{reason: "rate_limited"}}, socket}
    end
  end

  @impl true
  def handle_in(_event, _payload, socket) do
    case RateLimiting.check_message_rate(socket) do
      {:ok, socket} ->
        {:noreply, socket}

      {:error, :rate_limited} ->
        {:reply, {:error, %{reason: "rate_limited"}}, socket}
    end
  end

  defp assign_last_event_id(socket, %{"last_event_id" => last_id}) when is_integer(last_id) do
    Phoenix.Socket.assign(socket, :last_event_id, last_id)
  end

  defp assign_last_event_id(socket, _payload), do: socket

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
end
