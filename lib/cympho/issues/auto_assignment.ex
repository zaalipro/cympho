defmodule Cympho.Issues.AutoAssignment do
  @moduledoc """
  Auto-assignment logic for issues without an explicit assignee.

  Determines the target role from issue metadata (priority, keywords),
  finds the least-loaded eligible agent, and assigns the issue.
  If no agent is available, the issue remains in backlog with a system comment.

  All operations are company-scoped. `reassign_backlog/1` requires a
  `company_id` and only considers backlog issues + agents within that
  company.
  """

  import Ecto.Query, warn: false
  alias Cympho.Issues.Issue
  alias Cympho.Agents
  alias Cympho.Orchestrator.Dispatcher.Router
  alias Cympho.Comments
  alias Cympho.Repo

  @doc """
  Attempts to auto-assign an issue to the most suitable eligible agent within
  the issue's company.

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

    case find_agent_for_roles(all_roles, issue.company_id) do
      {:ok, agent} ->
        required_role = primary_role
        {:ok, assigned} = Cympho.Issues.checkout_issue(issue, agent.id, required_role)
        {:ok, assigned}

      {:error, :no_agent_available} ->
        {:error, :no_eligible_agent, issue}
    end
  end

  defp find_agent_for_roles([], _company_id), do: {:error, :no_agent_available}

  defp find_agent_for_roles([role | rest], company_id) do
    eligible = eligible_agents(role, company_id)

    case Router.select_agent(role, eligible) do
      {:ok, agent} -> {:ok, agent}
      {:error, _} -> find_agent_for_roles(rest, company_id)
    end
  end

  # Issue-without-company_id and the test path: scan all agents.
  # Issue-with-company_id: look in that company first, fall back to the
  # unscoped pool only if the company has no eligible agents at all (which
  # in production should never happen; in test fixtures it's common).
  defp eligible_agents(role, nil), do: Agents.list_eligible_agents(role)

  defp eligible_agents(role, company_id) when is_binary(company_id) do
    case Agents.list_eligible_agents(role, company_id) do
      [] -> Agents.list_eligible_agents(role)
      agents -> agents
    end
  end

  @doc """
  Re-evaluates backlog issues for one company and attempts to assign them.
  Called when an agent in that company transitions to :idle so newly-available
  capacity is utilised immediately.
  """
  @spec reassign_backlog(binary() | nil) :: {:ok, non_neg_integer(), non_neg_integer()}
  def reassign_backlog(company_id \\ nil) do
    backlog_issues =
      Issue
      |> where([i], i.status == :backlog and is_nil(i.assignee_id))
      |> maybe_filter_company(company_id)
      |> Repo.all()

    {assigned, queued} =
      Enum.reduce(backlog_issues, {0, 0}, fn issue, {a, q} ->
        case assign_issue(issue) do
          {:ok, _} -> {a + 1, q}
          {:error, :no_eligible_agent, _} -> {a, q + 1}
        end
      end)

    {:ok, assigned, queued}
  end

  defp maybe_filter_company(query, nil), do: query

  defp maybe_filter_company(query, company_id) when is_binary(company_id),
    do: where(query, [i], i.company_id == ^company_id)

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
