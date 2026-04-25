defmodule Cympho.RecentSearches do
  @moduledoc """
  The RecentSearches context for managing user search history.
  """

  import Ecto.Query, warn: false
  alias Cympho.Repo
  alias Cympho.RecentSearches.RecentSearch

  @doc """
  Gets a single recent_search by id.
  """
  def get_recent_search!(id), do: Repo.get!(RecentSearch, id)

  @doc """
  Gets recent searches for a user, ordered by most recently updated.
  """
  def list_recent_searches(user_id, limit \\ 10) do
    from(rs in RecentSearch,
      where: rs.user_id == ^user_id,
      order_by: [desc: rs.updated_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc """
  Records or updates a recent search for a user.
  If the search query and filters match an existing recent search, updates its count and timestamp.
  Otherwise creates a new recent search.
  """
  def record_search(user_id, company_id, query, filters \\ %{}) do
    existing =
      from(rs in RecentSearch,
        where:
          rs.user_id == ^user_id and
            rs.query == ^query and
            rs.filters == ^filters
      )
      |> Repo.one()

    if existing do
      existing
      |> RecentSearch.update_count_changeset()
      |> Repo.update()
    else
      %RecentSearch{
        user_id: user_id,
        company_id: company_id,
        query: query,
        filters: filters,
        search_count: 1
      }
      |> RecentSearch.changeset(%{})
      |> Repo.insert()
    end
  end

  @doc """
  Deletes a recent search.
  """
  def delete_recent_search(%RecentSearch{} = recent_search) do
    Repo.delete(recent_search)
  end

  @doc """
  Clears all recent searches for a user.
  """
  def clear_recent_searches(user_id) do
    from(rs in RecentSearch, where: rs.user_id == ^user_id)
    |> Repo.delete_all()
  end
end
