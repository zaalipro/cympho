defmodule CymphoWeb.ApprovalLive.Index do
  use CymphoWeb, :live_view
  alias Cympho.Approvals

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) && socket.assigns[:current_company] do
      Approvals.subscribe(socket.assigns.current_company.id)
    end

    {:ok,
     assign(socket,
       page_title: "Approvals",
       status_filter: nil,
       infinite_scroll: %{}
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
     |> init_stream(:approvals, &fetch_approvals(socket, &1, status))}
  end

  @impl true
  def handle_event("next-page", _params, socket) do
    status = socket.assigns.status_filter
    {:reply, %{}, load_next(socket, :approvals, &fetch_approvals(socket, &1, status))}
  end

  @impl true
  def handle_info({:approval_created, _approval}, socket) do
    {:noreply, reload_approvals(socket)}
  end

  def handle_info({:approval_resolved, _approval}, socket) do
    {:noreply, reload_approvals(socket)}
  end

  def handle_info({:approval_cancelled, _approval}, socket) do
    {:noreply, reload_approvals(socket)}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  defp reload_approvals(socket) do
    status = socket.assigns.status_filter
    reset_stream(socket, :approvals, &fetch_approvals(socket, &1, status))
  end

  defp fetch_approvals(socket, cursor, status) do
    case socket.assigns[:current_company] do
      nil ->
        %Cympho.Pagination.Page{entries: [], next_cursor: nil, has_more?: false}

      company ->
        Approvals.list_approvals_page(%{
          company_id: company.id,
          status: status,
          after: cursor
        })
    end
  end

  def status_badge_class(:pending), do: "bg-yellow-500/20 text-yellow-400"
  def status_badge_class(:approved), do: "bg-green-500/20 text-green-400"
  def status_badge_class(:denied), do: "bg-brand/20 text-brand"
  def status_badge_class(:cancelled), do: "bg-gray-500/20 text-gray-400"
  def status_badge_class(_), do: "bg-white/5 text-text-quaternary"
end
