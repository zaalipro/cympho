defmodule CymphoWeb.ApprovalLive.Show do
  use CymphoWeb, :live_view
  alias Cympho.Approvals

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Approvals.get_approval(id) do
      {:ok, approval} ->
        {:ok, assign(socket, approval: approval, page_title: "Approval #{approval.id}")}

      {:error, :not_found} ->
        {:ok, push_navigate(socket, to: ~p"/approvals")}
    end
  end

  @impl true
  def handle_event("approve", _params, socket) do
    case Approvals.resolve_approval(socket.assigns.approval.id, :approved, %{
           resolved_by_user_id: nil,
           resolution_reason: "Approved via UI"
         }) do
      {:ok, approval} ->
        {:noreply, assign(socket, :approval, approval)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to approve")}
    end
  end

  def handle_event("deny", _params, socket) do
    case Approvals.resolve_approval(socket.assigns.approval.id, :denied, %{
           resolved_by_user_id: nil,
           resolution_reason: "Denied via UI"
         }) do
      {:ok, approval} ->
        {:noreply, assign(socket, :approval, approval)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to deny")}
    end
  end

  @impl true
  def handle_info({:approval_resolved, updated}, socket) do
    if socket.assigns.approval.id == updated.id do
      {:noreply, assign(socket, :approval, updated)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_, socket), do: {:noreply, socket}

  def status_badge_class(:pending), do: "bg-yellow-500/20 text-yellow-400"
  def status_badge_class(:approved), do: "bg-green-500/20 text-green-400"
  def status_badge_class(:denied), do: "bg-red-500/20 text-red-400"
  def status_badge_class(:cancelled), do: "bg-gray-500/20 text-gray-400"
  def status_badge_class(_), do: "bg-white/5 text-text-quaternary"
end
