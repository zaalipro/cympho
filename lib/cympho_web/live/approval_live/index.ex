defmodule CymphoWeb.ApprovalLive.Index do
  use CymphoWeb, :live_view
  alias Cympho.Approvals

  @impl true
  def mount(_params, _session, socket) do
    Approvals.subscribe()

    {:ok,
     assign(socket,
       page_title: "Approvals",
       approvals: Approvals.list_approvals(),
       status_filter: nil
     )}
  end

  @impl true
  def handle_params(params, _url, socket) do
    status =
      case Map.get(params, "status") do
        nil -> nil
        "" -> nil
        s -> String.to_existing_atom(s)
      end

    {:noreply,
     socket
     |> assign(:status_filter, status)
     |> assign(:approvals, Approvals.list_approvals(%{status: status}))}
  end

  @impl true
  def handle_info({:approval_created, _approval}, socket) do
    {:noreply, assign(socket, :approvals, Approvals.list_approvals())}
  end

  def handle_info({:approval_resolved, _approval}, socket) do
    {:noreply, assign(socket, :approvals, Approvals.list_approvals())}
  end

  def handle_info({:approval_cancelled, _approval}, socket) do
    {:noreply, assign(socket, :approvals, Approvals.list_approvals())}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  def status_badge_class(:pending), do: "bg-yellow-500/20 text-yellow-400"
  def status_badge_class(:approved), do: "bg-green-500/20 text-green-400"
  def status_badge_class(:denied), do: "bg-red-500/20 text-red-400"
  def status_badge_class(:cancelled), do: "bg-gray-500/20 text-gray-400"
  def status_badge_class(_), do: "bg-white/5 text-text-quaternary"
end
