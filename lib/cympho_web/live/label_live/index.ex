defmodule CymphoWeb.LabelLive.Index do
  use CymphoWeb, :live_view

  alias Cympho.Labels
  alias Cympho.Labels.Label

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :labels, Labels.list_labels())}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Labels")
    |> assign(:label, nil)
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New Label")
    |> assign(:label, %Label{})
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    socket
    |> assign(:page_title, "Edit Label")
    |> assign(:label, Labels.get_label!(id))
  end

  @impl true
  def handle_info({:label_created, label}, socket) do
    {:noreply, update(socket, :labels, fn labels -> [label | labels] end)}
  end

  def handle_info({:label_updated, updated_label}, socket) do
    {:noreply,
     update(socket, :labels, fn labels ->
       Enum.map(labels, fn label ->
         if label.id == updated_label.id, do: updated_label, else: label
       end)
     end)}
  end

  def handle_info({:label_deleted, deleted_id}, socket) do
    {:noreply,
     update(socket, :labels, fn labels ->
       Enum.filter(labels, fn label -> label.id != deleted_id end)
     end)}
  end

  @impl true
  def handle_event("delete_label", %{"id" => id}, socket) do
    label = Labels.get_label!(id)
    {:ok, _} = Labels.delete_label(label)
    {:noreply, socket}
  end
end
