defmodule CymphoWeb.InboxLive.Index do
  use CymphoWeb, :live_view
  alias Cympho.Inbox
  alias Cympho.Agents

  @impl true
  def mount(_params, _session, socket) do
    agents = Agents.list_agents()

    socket =
      socket
      |> assign(:page_title, "Inbox")
      |> assign(:agents, agents)
      |> assign(:selected_agent_id, List.first(agents) && List.first(agents).id)

    if connected?(socket) do
      if socket.assigns.selected_agent_id do
        Inbox.subscribe(socket.assigns.selected_agent_id)
      end
      if socket.assigns[:current_company] do
        CymphoWeb.Events.subscribe_to_runs(socket.assigns.current_company.id)
      end
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    status = params["status"] || ""
    agent_id = params["agent_id"] || socket.assigns[:selected_agent_id] || ""

    socket =
      socket
      |> assign(:current_status, status)
      |> assign(:selected_agent_id, agent_id)
      |> load_inbox()

    {:noreply, socket}
  end

  @impl true
  def handle_info({:inbox_updated, _state}, socket) do
    {:noreply, load_inbox(socket)}
  end

  def handle_info({:inbox_created, _state}, socket) do
    {:noreply, load_inbox(socket)}
  end

  def handle_info({:run_status_changed, payload}, socket) do
    selected_agent_id = socket.assigns[:selected_agent_id]
    socket = if payload[:agent_id] == selected_agent_id do
      {message, type} = case payload do
        %{new_status: "completed"} -> {"Agent completed a run", "success"}
        %{new_status: "failed"} -> {"Agent run failed", "error"}
        %{new_status: "cancelled"} -> {"Agent run cancelled", "warning"}
        _ -> {"Agent run status changed", "info"}
      end
      push_event(socket, "toast", %{message: message, type: type, key: "run_#{payload[:run_id]}"})
    else
      socket
    end
    {:noreply, socket}
  end

  @impl true
  def handle_event("mark_read", %{"issue_id" => issue_id}, socket) do
    agent_id = socket.assigns.selected_agent_id
    {:ok, _} = Inbox.mark_read(issue_id, agent_id)
    {:noreply, load_inbox(socket)}
  end

  def handle_event("dismiss", %{"issue_id" => issue_id}, socket) do
    agent_id = socket.assigns.selected_agent_id
    {:ok, _} = Inbox.dismiss(issue_id, agent_id)
    {:noreply, load_inbox(socket)}
  end

  def handle_event("archive", %{"issue_id" => issue_id}, socket) do
    agent_id = socket.assigns.selected_agent_id
    {:ok, _} = Inbox.archive(issue_id, agent_id)
    {:noreply, load_inbox(socket)}
  end

  def handle_event("restore", %{"issue_id" => issue_id}, socket) do
    agent_id = socket.assigns.selected_agent_id
    {:ok, _} = Inbox.restore(issue_id, agent_id)
    {:noreply, load_inbox(socket)}
  end

  def handle_event("filter_status", %{"status" => status}, socket) do
    {:noreply, push_patch(socket, to: build_url(socket, %{"status" => status}))}
  end

  def handle_event("select_agent", %{"agent_id" => agent_id}, socket) do
    if connected?(socket) && agent_id != "" do
      Inbox.subscribe(agent_id)
    end

    socket =
      socket
      |> assign(:selected_agent_id, agent_id)
      |> load_inbox()

    {:noreply, push_patch(socket, to: build_url(socket, %{"agent_id" => agent_id}))}
  end

  defp load_inbox(socket) do
    agent_id = socket.assigns[:selected_agent_id]
    status = socket.assigns[:current_status]

    opts = if status && status != "", do: [status: status], else: []

    items =
      if agent_id && agent_id != "" do
        Inbox.list_inbox_for_agent(agent_id, opts)
      else
        []
      end

    assign(socket, :inbox_items, items)
  end

  defp build_url(socket, overrides) do
    status = Map.get(overrides, "status", socket.assigns.current_status)
    agent_id = Map.get(overrides, "agent_id", socket.assigns.selected_agent_id)

    query =
      %{
        status: status,
        agent_id: agent_id
      }
      |> Enum.reject(fn {_k, v} -> v in ["", nil] end)
      |> Enum.into(%{})

    ~p"/inbox?#{query}"
  end

  defp unread_dot("unread"), do: "bg-blue-400"
  defp unread_dot(_), do: "bg-transparent"

  defp status_badge_class("unread"), do: "bg-blue-500/20 text-blue-400"
  defp status_badge_class("read"), do: "bg-gray-500/20 text-gray-400"
  defp status_badge_class("dismissed"), do: "bg-yellow-500/20 text-yellow-400"
  defp status_badge_class("archived"), do: "bg-red-500/20 text-red-400"
  defp status_badge_class(_), do: "bg-gray-500/20 text-gray-400"

  defp issue_link(issue) when is_nil(issue), do: "#"
  defp issue_link(issue), do: ~p"/issues/#{issue.id}"

  defp format_timestamp(nil), do: "-"
  defp format_timestamp(dt), do: Calendar.strftime(dt, "%b %d, %H:%M")
end
