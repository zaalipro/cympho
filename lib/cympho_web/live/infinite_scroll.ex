defmodule CymphoWeb.InfiniteScroll do
  @moduledoc """
  Shared helpers for streamed, keyset-paginated (infinite-scroll) lists.

  Pairs with the `InfiniteScroll` JS hook and the `<.infinite_scroll>` /
  `<.infinite_scroll_footer>` components. Each list supplies a stream `key`
  (atom) and a `fetch` fun `(cursor -> Cympho.Pagination.Page.t())`. Per-key
  state lives under `@infinite_scroll[key] = %{cursor, has_more?}`.

  The cursor is opaque here: this module stores whatever `page.next_cursor` was
  and passes it back to `fetch`, so a page may be keyset- or offset-backed.

  ## Usage

      # mount: seed the state map
      socket = assign(socket, :infinite_scroll, %{})

      # mount / handle_params, after filters are applied
      socket = init_stream(socket, :activities, &fetch_activities(socket, &1))

      # the next-page handler — reply so the JS in-flight guard clears precisely
      def handle_event("next-page", _params, socket) do
        {:reply, %{}, load_next(socket, :activities, &fetch_activities(socket, &1))}
      end

  The template reads `@infinite_scroll[:activities].has_more?`.
  """
  import Phoenix.LiveView, only: [stream: 4, stream_insert: 4, stream_delete: 3]
  import Phoenix.Component, only: [assign: 3]

  alias Cympho.Pagination.Page

  @doc """
  Reset the stream and load the first page.

  Use in `mount`/`handle_params` and whenever a filter changes (a cursor is only
  valid for the filter set it was produced under).
  """
  def init_stream(socket, key, fetch) when is_atom(key) and is_function(fetch, 1) do
    page = fetch.(nil)

    socket
    |> stream(key, page.entries, reset: true)
    |> put_state(key, page)
  end

  @doc "Alias for `init_stream/3` — clear and reload from the first page on filter change."
  def reset_stream(socket, key, fetch), do: init_stream(socket, key, fetch)

  @doc "Append the next page if one exists. Use in the `next-page` handler."
  def load_next(socket, key, fetch) do
    case state_for(socket, key) do
      %{has_more?: true, cursor: cursor} ->
        page = fetch.(cursor)

        socket
        |> stream(key, page.entries, [])
        |> put_state(key, page)

      _ ->
        socket
    end
  end

  @doc "Live-prepend one item (e.g. a PubSub event) without disturbing the cursor."
  def prepend(socket, key, item), do: stream_insert(socket, key, item, at: 0)

  @doc "Remove one item from the stream (e.g. on delete)."
  def remove(socket, key, item), do: stream_delete(socket, key, item)

  @doc "Whether the given stream has more pages (safe before `init_stream/3`)."
  def has_more?(socket, key) do
    case state_for(socket, key) do
      %{has_more?: more} -> more
      _ -> false
    end
  end

  defp state_for(socket, key), do: get_in(socket.assigns, [:infinite_scroll, key])

  defp put_state(socket, key, %Page{} = page) do
    states = Map.get(socket.assigns, :infinite_scroll, %{})
    state = %{cursor: page.next_cursor, has_more?: page.has_more?}
    assign(socket, :infinite_scroll, Map.put(states, key, state))
  end
end
