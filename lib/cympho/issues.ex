defmodule Cympho.Issues do
  @moduledoc """
  The Issues context for managing issues and their CRUD operations.
  """
  import Ecto.Query, warn: false
  alias Cympho.Repo
  alias Cympho.Issues.Issue
  alias Cympho.Comments

  @doc """
  Returns the list of issues.
  """
  def list_issues do
    Repo.all(Issue) |> Repo.preload(:comments)
  end

  @doc """
  Gets a single issue by id.
  """
  def get_issue!(id), do: Repo.get!(Issue, id) |> Repo.preload(:comments)

  @doc """
  Gets a single issue by id, returns {:ok, issue} or {:error, :not_found}.
  """
  def get_issue(id), do: Repo.get(Issue, id) |> case do
    nil -> {:error, :not_found}
    issue -> {:ok, Repo.preload(issue, :comments)}
  end

  @doc """
  Creates an issue.
  """
  def create_issue(attrs \\ %{}) do
    %Issue{}
    |> Issue.changeset(attrs)
    |> Repo.insert()
    |> then(fn {:ok, issue} ->
      Phoenix.PubSub.broadcast(Cympho.PubSub, "issues", {:issue_created, issue})
      {:ok, Repo.preload(issue, :comments)}
    end)
  end

  @doc """
  Updates an issue.
  """
  def update_issue(%Issue{} = issue, attrs) do
    issue
    |> Issue.changeset(attrs)
    |> Repo.update()
    |> then(fn {:ok, issue} ->
      Phoenix.PubSub.broadcast(Cympho.PubSub, "issues", {:issue_updated, issue})
      {:ok, Repo.preload(issue, :comments)}
    end)
  end

  @doc """
  Deletes an issue.
  """
  def delete_issue(%Issue{} = issue) do
    Repo.delete(issue)
    |> then(fn {:ok, _issue} ->
      Phoenix.PubSub.broadcast(Cympho.PubSub, "issues", {:issue_deleted, issue.id})
      :ok
    end)
  end

  @doc """
  Subscribes to issue updates.
  """
  def subscribe do
    Phoenix.PubSub.subscribe(Cympho.PubSub, "issues")
  end

  @doc """
  Returns a changeset for creating a new issue.
  """
  def change_issue(%Issue{} = issue, attrs \\ %{}) do
    Issue.changeset(issue, attrs)
  end
end
