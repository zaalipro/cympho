defmodule Cympho.PaginationTest do
  use Cympho.DataCase, async: true

  alias Cympho.Pagination
  alias Cympho.Pagination.Page
  alias Cympho.Companies.Company

  # Insert a company directly (bypassing the changeset) so we control
  # inserted_at to the second — schema defaults populate the other columns.
  defp company(prefix, name, slug, inserted_at) do
    Repo.insert!(%Company{
      name: name,
      slug: "#{prefix}-#{slug}",
      inserted_at: inserted_at,
      updated_at: inserted_at
    })
  end

  defp unique_prefix do
    "pagination-#{System.unique_integer([:positive])}"
  end

  defp scoped_companies(prefix) do
    from(c in Company, where: like(c.slug, ^"#{prefix}-%"))
  end

  defp at(offset_seconds) do
    ~U[2026-01-01 00:00:00Z]
    |> DateTime.add(offset_seconds, :second)
    |> DateTime.truncate(:second)
  end

  # Walk every page, accumulating ids in order.
  defp collect_ids(queryable, opts) do
    do_collect(queryable, opts, nil, [])
  end

  defp do_collect(queryable, opts, cursor, acc) do
    page = Pagination.page(queryable, Keyword.put(opts, :after, cursor))
    acc = acc ++ Enum.map(page.entries, & &1.id)

    if page.has_more?, do: do_collect(queryable, opts, page.next_cursor, acc), else: acc
  end

  describe "page/2 has_more?/cursor bookkeeping" do
    test "a full page reports has_more? with a non-nil cursor" do
      prefix = unique_prefix()
      queryable = scoped_companies(prefix)
      for i <- 1..5, do: company(prefix, "Co #{i}", "co-#{i}", at(i))

      page = Pagination.page(queryable, limit: 2)

      assert %Page{entries: entries, has_more?: true, next_cursor: cursor} = page
      assert length(entries) == 2
      assert is_map(cursor)
      assert Map.has_key?(cursor, :inserted_at) and Map.has_key?(cursor, :id)
    end

    test "a partial final page reports has_more? false and a nil cursor" do
      prefix = unique_prefix()
      queryable = scoped_companies(prefix)
      for i <- 1..3, do: company(prefix, "Co #{i}", "co-#{i}", at(i))

      page = Pagination.page(queryable, limit: 10)

      assert %Page{entries: entries, has_more?: false, next_cursor: nil} = page
      assert length(entries) == 3
    end

    test "an empty result returns the empty page" do
      queryable = scoped_companies(unique_prefix())

      assert %Page{entries: [], has_more?: false, next_cursor: nil} =
               Pagination.page(queryable, limit: 10)
    end
  end

  describe "page/2 keyset correctness" do
    test "chained pages are contiguous with no overlap or gap (desc default)" do
      prefix = unique_prefix()
      queryable = scoped_companies(prefix)
      inserted = for i <- 1..7, do: company(prefix, "Co #{i}", "co-#{i}", at(i))
      # default order is inserted_at desc, id desc → newest first
      expected = inserted |> Enum.reverse() |> Enum.map(& &1.id)

      assert collect_ids(queryable, limit: 2) == expected
    end

    test "same-second ties paginate with no dup/skip (id tiebreak)" do
      prefix = unique_prefix()
      queryable = scoped_companies(prefix)
      ts = at(0)
      inserted = for i <- 1..6, do: company(prefix, "Co #{i}", "co-#{i}", ts)

      # All share inserted_at, so the total order is purely id desc.
      expected = inserted |> Enum.sort_by(& &1.id, :desc) |> Enum.map(& &1.id)

      got = collect_ids(queryable, limit: 2)

      assert got == expected
      assert length(Enum.uniq(got)) == length(got)
    end

    test "ascending cursor fields paginate in ascending order" do
      prefix = unique_prefix()
      queryable = scoped_companies(prefix)
      for i <- 1..5, do: company(prefix, "Co #{i}", "co-#{i}", at(i))

      expected =
        Repo.all(from c in queryable, order_by: [asc: c.name, asc: c.id], select: c.id)

      assert collect_ids(queryable, limit: 2, cursor_fields: [{:name, :asc}, {:id, :asc}]) ==
               expected
    end

    test "mixed-direction cursor fields stay contiguous" do
      prefix = unique_prefix()
      queryable = scoped_companies(prefix)
      ts = at(0)
      # Same second so the second (asc id) column drives ordering within the tie.
      for i <- 1..6, do: company(prefix, "Co #{i}", "co-#{i}", ts)

      expected =
        Repo.all(from c in queryable, order_by: [desc: c.inserted_at, asc: c.id], select: c.id)

      got =
        collect_ids(queryable,
          limit: 2,
          cursor_fields: [{:inserted_at, :desc}, {:id, :asc}]
        )

      assert got == expected
      assert length(Enum.uniq(got)) == length(got)
    end
  end
end
