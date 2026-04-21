defmodule Cympho.Issues.AutoAssignment do
  @moduledoc """
  Auto-assignment logic for issues without an explicit assignee.

  Determines the target role from issue metadata (priority, keywords),
  finds the least-loaded eligible agent, and assigns the issue.
  If no agent is available, the issue remains in backlog with a system comment.
  """

  import Ecto.Query, warn: false
  alias Cympho.Issues.Issue
  alias Cympho.Agents
  alias Cympho.Orchestrator.Dispatcher.Router
  alias Cympho.Comments
  alias Cympho.Repo

  @doc """
  Attempts to auto-assign an issue to the most suitable eligible agent.

  Returns:
    - `{:ok, issue}` with assignee set if assignment succeeded
    - `{:error, :no_eligible_agent, issue}` if no agent could be assigned
      (issue remains in its current state; caller should handle accordingly)
  """
  @spec assign_issue(Issue.t()) :: {:ok, Issue.t()} | {:error, :no_eligible_agent, Issue.t()}
  def assign_issue(%Issue{} = issue) do
    if issue.assignee_id do
      {:ok, issue}
    else
      do_assign_issue(issue)
    end
  end

  defp do_assign_issue(%Issue{} = issue) do
    primary_role = Router.infer_role(issue)
    fallback_roles = Router.fallback_chain(primary_role)
    all_roles = [primary_role | fallback_roles]

    case find_agent_for_roles(all_roles) do
      {:ok, agent} ->
        required_role = primary_role
        {:ok, assigned} = Cympho.Issues.checkout_issue(issue, agent.id, required_role)
        {:ok, assigned}

      {:error, :no_agent_available} ->
        {:error, :no_eligible_agent, issue}
    end
  end

  defp find_agent_for_roles([]), do: {:error, :no_agent_available}

  defp find_agent_for_roles([role | rest]) do
    eligible = Agents.list_eligible_agents(role)

    case Router.select_agent(role, eligible) do
      {:ok, agent} -> {:ok, agent}
      {:error, _} -> find_agent_for_roles(rest)
    end
  end

  @doc """
  Re-evaluates all backlog issues with no assignee and attempts to assign them.
  Called when an agent transitions to :idle to ensure newly-available capacity
  is immediately utilised.
  """
  @spec reassign_backlog :: {:ok, non_neg_integer(), non_neg_integer()}
  def reassign_backlog do
    backlog_issues =
      Issue
      |> where([i], i.status == :backlog and is_nil(i.assignee_id))
      |> Repo.all()

    results =
      Enum.map(backlog_issues, fn issue ->
        case assign_issue(issue) do
          {:ok, _} -> :assigned
          {:error, :no_eligible_agent, _} -> :queued
        end
      end)

    assigned = Enum.count(results, &(&1 == :assigned))
    queued = Enum.count(results, &(&1 == :queued))
    {:ok, assigned, queued}
  end

  @doc """
  Adds a system comment to an issue indicating it is queued for manual assignment.
  """
  @spec queue_for_assignment(Issue.t()) :: {:ok, Comment.t()} | {:error, term()}
  def queue_for_assignment(%Issue{} = issue) do
    Comments.create_comment(%{
      body: "No eligible agents available — queued for assignment.",
      author_type: "system",
      author_id: "00000000-0000-0000-0000-000000000000",
      issue_id: issue.id
    })
  end
end
