defmodule Cympho.Search do
  @moduledoc """
  Full-text search across issues and comments using PostgreSQL tsvector.
  """
  import Ecto.Query, warn: false
  alias Cympho.Repo
  alias Cympho.Issues.Issue
  alias Cympho.Comments.Comment

  @doc """
  Search issues and comments by query string.
  Returns a map with :issues and :comments lists.

  Options:
    - :limit - max results per category (default 20)
  """
  def search(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    tsquery = build_tsquery(query)

    issues =
      from i in Issue,
        where: fragment("search_vector @@ ?", ^tsquery),
        order_by: fragment("ts_rank(search_vector, ?) DESC", ^tsquery),
        limit: ^limit,
        preload: [:comments, :blocked_by, :blocks, :assignee]
      |> Repo.all()

    comments =
      from c in Comment,
        where: fragment("search_vector @@ ?", ^tsquery),
        order_by: fragment("ts_rank(search_vector, ?) DESC", ^tsquery),
        limit: ^limit,
        preload: [:issue]
      |> Repo.all()

    %{issues: issues, comments: comments}
  end

  @doc """
  Search only issues, returning them ranked by relevance.
  Title matches are weighted higher than description matches (via setweight 'A' in trigger).
  """
  def search_issues(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    tsquery = build_tsquery(query)

    from i in Issue,
      where: fragment("search_vector @@ ?", ^tsquery),
      order_by: fragment("ts_rank(search_vector, ?) DESC", ^tsquery),
      limit: ^limit,
      preload: [:comments, :blocked_by, :blocks, :assignee]
    |> Repo.all()
  end

  @doc """
  Build a plainto_tsquery from user input.
  """
  def build_tsquery(query) when is_binary(query) and byte_size(query) > 0 do
    fragment("plainto_tsquery('english', ?)", ^query)
  end

  def build_tsquery(_), do: fragment("''::tsquery")
end
