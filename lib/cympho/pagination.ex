defmodule Cympho.Pagination.Page do
  @moduledoc """
  One page of keyset-paginated results.

  * `entries` — the rows for this page (already trimmed to the requested limit).
  * `next_cursor` — an opaque map of the last entry's cursor-field values, to be
    passed back as `:after` for the following page. `nil` when there are no more.
  * `has_more?` — whether another page exists after this one.
  """
  @enforce_keys [:entries, :next_cursor, :has_more?]
  defstruct entries: [], next_cursor: nil, has_more?: false

  @type t :: %__MODULE__{
          entries: [struct()],
          next_cursor: map() | nil,
          has_more?: boolean()
        }
end

defmodule Cympho.Pagination do
  @moduledoc """
  Shared keyset (cursor) pagination for infinite-scroll lists.

  `page/2` paginates an Ecto query by an ordered list of `cursor_fields`
  (each `{field, :asc | :desc}`) and returns a `Cympho.Pagination.Page`. It
  fetches one extra row to compute `has_more?`, and derives the next cursor from
  the last returned row.

  Keyset (rather than offset) is used because these feeds are append-heavy: with
  `OFFSET`, a row inserted at the head between loads shifts every later row down,
  producing a duplicate at each page boundary; keyset anchors on the last row's
  sort values, so concurrent head-inserts never duplicate or skip seen rows. It
  is also O(1) for deep pages (no scan-and-discard).

  The helper **owns ordering**: it strips any `order_by` already on the query and
  re-applies one derived from `cursor_fields`, guaranteeing the WHERE comparison
  and the ORDER BY always use identical columns/directions. Callers therefore
  pass only their `where` filters (and joins/preloads) plus `cursor_fields`.

  The cursor is a plain map held in server-side socket assigns and is never sent
  to or accepted from the client, so it needs no signing or opaque encoding.

  ## Caller obligation

  A cursor is only valid for the exact filter set it was produced under. When any
  filter changes, discard the stored cursor (pass `after: nil`) and reload from
  the first page.
  """
  import Ecto.Query
  alias Cympho.Pagination.Page

  @default_limit 50
  @max_limit 200
  @default_cursor_fields [{:inserted_at, :desc}, {:id, :desc}]

  @doc """
  Fetch one keyset page of `queryable`.

  ## Options

    * `:limit` — page size, default `#{@default_limit}`, clamped to `#{@max_limit}`.
    * `:after` — the previous page's `next_cursor` map, or `nil` for the first page.
    * `:cursor_fields` — ordered `[{field, :asc | :desc}, ...]`, default
      `#{inspect(@default_cursor_fields)}`. The final field must be unique (an `id`
      tiebreak) for correctness under same-value ties.
    * `:repo` — defaults to `Cympho.Repo`.
  """
  @spec page(Ecto.Queryable.t(), keyword()) :: Page.t()
  def page(queryable, opts \\ []) do
    repo = Keyword.get(opts, :repo, Cympho.Repo)
    limit = opts |> Keyword.get(:limit, @default_limit) |> clamp_limit()
    cursor_fields = Keyword.get(opts, :cursor_fields, @default_cursor_fields)
    after_cursor = Keyword.get(opts, :after)

    rows =
      queryable
      |> exclude(:order_by)
      |> apply_cursor_filter(after_cursor, cursor_fields)
      |> apply_ordering(cursor_fields)
      |> limit(^(limit + 1))
      |> repo.all()

    has_more? = length(rows) > limit
    entries = Enum.take(rows, limit)

    %Page{
      entries: entries,
      has_more?: has_more?,
      next_cursor: if(has_more?, do: build_cursor(List.last(entries), cursor_fields))
    }
  end

  defp clamp_limit(n) when is_integer(n) and n > 0, do: min(n, @max_limit)
  defp clamp_limit(_), do: @default_limit

  defp apply_ordering(query, cursor_fields) do
    order = Enum.map(cursor_fields, fn {field, dir} -> {dir, field} end)
    order_by(query, ^order)
  end

  defp apply_cursor_filter(query, nil, _cursor_fields), do: query

  defp apply_cursor_filter(query, cursor, cursor_fields) do
    where(query, ^build_keyset_dynamic(cursor_fields, cursor))
  end

  # Strict comparison on the final cursor column, in its sort direction.
  defp build_keyset_dynamic([{field, dir}], cursor) do
    column_compare(field, dir, Map.fetch!(cursor, field))
  end

  # head strictly-past-cursor  OR  (head == cursor AND the rest of the keyset)
  defp build_keyset_dynamic([{field, dir} | rest], cursor) do
    value = Map.fetch!(cursor, field)
    rest_dynamic = build_keyset_dynamic(rest, cursor)

    dynamic(
      [r],
      ^column_compare(field, dir, value) or
        (field(r, ^field) == ^value and ^rest_dynamic)
    )
  end

  defp column_compare(field, :desc, value), do: dynamic([r], field(r, ^field) < ^value)
  defp column_compare(field, :asc, value), do: dynamic([r], field(r, ^field) > ^value)

  defp build_cursor(entry, cursor_fields) do
    Map.new(cursor_fields, fn {field, _dir} -> {field, Map.fetch!(entry, field)} end)
  end
end
