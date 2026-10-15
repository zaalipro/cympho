defmodule CymphoWeb.DocsLive.Index do
  @moduledoc """
  Main LiveView controller for Cympho's In-App Documentation Hub.
  Supports authenticated operator access and guest external browsing.
  """
  use CymphoWeb, :live_view

  alias Cympho.Docs.Content
  alias Cympho.Docs.SearchIndex
  import CymphoWeb.DocsLive.Components.SearchModal
  import CymphoWeb.DocsLive.Components.SidebarComponent
  import CymphoWeb.DocsLive.Components.TocComponent

  @impl true
  def mount(_params, _session, socket) do
    topics = Content.topics()

    socket =
      socket
      |> assign(:topics, topics)
      |> assign(:search_open, false)
      |> assign(:search_query, "")
      |> assign(:search_results, [])
      |> assign(:selected_index, 0)
      |> assign(:mobile_sidebar_open, false)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    topic_slug = params["topic"]
    section_slug = params["section"]

    doc = resolve_doc(topic_slug, section_slug)

    socket =
      socket
      |> assign(:active_doc, doc)
      |> assign(:active_topic_slug, doc.topic_slug)
      |> assign(:active_section_slug, doc.section_slug)
      |> assign(:page_title, "#{doc.title} · Documentation")
      |> assign(:mobile_sidebar_open, false)

    {:noreply, socket}
  end

  defp resolve_doc(nil, nil), do: Content.first_doc()

  defp resolve_doc(topic_slug, nil) do
    case Content.get_topic(topic_slug) do
      nil -> Content.first_doc()
      _topic -> Content.default_doc_for_topic(topic_slug)
    end
  end

  defp resolve_doc(topic_slug, section_slug) do
    case Content.get_doc(topic_slug, section_slug) do
      nil ->
        case Content.get_topic(topic_slug) do
          nil -> Content.first_doc()
          _topic -> Content.default_doc_for_topic(topic_slug)
        end

      doc ->
        doc
    end
  end

  # ---------------------------------------------------------------------------
  # Event Handlers
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("open_search", _params, socket) do
    {:noreply,
     socket
     |> assign(:search_open, true)
     |> assign(:search_query, "")
     |> assign(:search_results, [])
     |> assign(:selected_index, 0)}
  end

  @impl true
  def handle_event("close_search", _params, socket) do
    {:noreply, assign(socket, :search_open, false)}
  end

  @impl true
  def handle_event("toggle_mobile_sidebar", _params, socket) do
    {:noreply, update(socket, :mobile_sidebar_open, &not/1)}
  end

  @impl true
  def handle_event("close_mobile_sidebar", _params, socket) do
    {:noreply, assign(socket, :mobile_sidebar_open, false)}
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    results = SearchIndex.search(query, limit: 12)

    {:noreply,
     socket
     |> assign(:search_query, query)
     |> assign(:search_results, results)
     |> assign(:selected_index, 0)}
  end

  @impl true
  def handle_event("search_suggest", %{"query" => query}, socket) do
    results = SearchIndex.search(query, limit: 12)

    {:noreply,
     socket
     |> assign(:search_query, query)
     |> assign(:search_results, results)
     |> assign(:selected_index, 0)}
  end

  @impl true
  def handle_event("search_submit", _params, socket) do
    case Enum.at(socket.assigns.search_results, socket.assigns.selected_index) do
      %{doc: doc} ->
        socket =
          socket
          |> assign(:search_open, false)
          |> push_patch(to: ~p"/docs/#{doc.topic_slug}/#{doc.section_slug}")

        {:noreply, socket}

      nil ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("search_keydown", %{"key" => key}, socket) do
    case key do
      "Escape" ->
        {:noreply, assign(socket, :search_open, false)}

      "ArrowDown" ->
        total = length(socket.assigns.search_results)
        new_idx = if total > 0, do: min(socket.assigns.selected_index + 1, total - 1), else: 0
        {:noreply, assign(socket, :selected_index, new_idx)}

      "ArrowUp" ->
        new_idx = max(socket.assigns.selected_index - 1, 0)
        {:noreply, assign(socket, :selected_index, new_idx)}

      "Enter" ->
        case Enum.at(socket.assigns.search_results, socket.assigns.selected_index) do
          %{doc: doc} ->
            socket =
              socket
              |> assign(:search_open, false)
              |> push_patch(to: ~p"/docs/#{doc.topic_slug}/#{doc.section_slug}")

            {:noreply, socket}

          nil ->
            {:noreply, socket}
        end

      "/" ->
        if not socket.assigns.search_open do
          {:noreply,
           socket
           |> assign(:search_open, true)
           |> assign(:search_query, "")
           |> assign(:search_results, [])
           |> assign(:selected_index, 0)}
        else
          {:noreply, socket}
        end

      _ ->
        {:noreply, socket}
    end
  end
end
