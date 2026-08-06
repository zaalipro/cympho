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
  alias Cympho.Agents.Agent
  alias Cympho.Orchestrator.Dispatcher.Router
  alias Cympho.Comments
  alias Cympho.Repo

  @waiting_owner_statuses [:backlog, :todo]
  @repo_delivery_roles Agent.pr_delivery_roles()

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

  @doc """
  Assigns the best matching owner without checking the issue out.

  Review-mode workflows use this before pinning focused dispatch: the owner can
  see who will pick up a delegated child issue, while the issue stays in its
  current queue state until runtime is explicitly started.
  """
  @spec assign_owner_for_dispatch(Issue.t()) ::
          {:ok, Issue.t()} | {:error, :no_eligible_agent, Issue.t()}
  def assign_owner_for_dispatch(%Issue{assignee_id: assignee_id} = issue)
      when not is_nil(assignee_id),
      do: {:ok, issue}

  def assign_owner_for_dispatch(%Issue{} = issue) do
    primary_role = Router.infer_role(issue)

    case find_agent_for_roles(assignment_roles(primary_role), issue.company_id) do
      {:ok, agent} ->
        Cympho.Issues.update_issue(issue, %{
          assignee_id: agent.id,
          assigned_role: to_string(primary_role)
        })

      {:error, :no_agent_available} ->
        {:error, :no_eligible_agent, issue}
    end
  end

  @doc """
  Assigns an owner and promotes `:backlog` → `:todo` so the dispatcher / heartbeat
  can claim the issue. Never checks out to `:in_progress`.
  """
  @spec assign_and_promote_for_dispatch(Issue.t()) ::
          {:ok, Issue.t()} | {:error, :no_eligible_agent, Issue.t()}
  def assign_and_promote_for_dispatch(%Issue{} = issue) do
    with {:ok, assigned} <- assign_owner_for_dispatch(issue) do
      promote_backlog_to_todo(assigned)
    end
  end

  defp do_assign_issue(%Issue{} = issue) do
    primary_role = Router.infer_role(issue)

    case find_agent_for_roles(assignment_roles(primary_role), issue.company_id) do
      {:ok, agent} ->
        required_role = primary_role
        {:ok, assigned} = Cympho.Issues.checkout_issue(issue, agent.id, required_role)
        {:ok, assigned}

      {:error, :no_agent_available} ->
        {:error, :no_eligible_agent, issue}
    end
  end

  defp promote_backlog_to_todo(%Issue{status: status} = issue)
       when status in [:backlog, "backlog"] do
    Cympho.Issues.update_issue(issue, %{status: :todo})
  end

  defp promote_backlog_to_todo(%Issue{} = issue), do: {:ok, issue}

  defp assignment_roles(role) when role in @repo_delivery_roles, do: [role]
  defp assignment_roles(role), do: [role | Router.fallback_chain(role)]

  defp find_agent_for_roles([], _company_id), do: {:error, :no_agent_available}

  defp find_agent_for_roles([role | rest], company_id) do
    eligible = eligible_agents(role, company_id)

    case Router.select_agent(role, eligible) do
      {:ok, agent} -> {:ok, agent}
      {:error, _} -> find_agent_for_roles(rest, company_id)
    end
  end

  # Fail-closed: never scan unscoped agents. Issues without a company_id get
  # no eligible owners (same posture as Dispatcher / checkout).
  defp eligible_agents(role, company_id) when is_binary(company_id),
    do: Agents.list_eligible_agents(role, company_id)

  defp eligible_agents(_role, _company_id), do: []

  @doc """
  Re-evaluates backlog issues for one company and prepares them for dispatch.

  Assigns an owner, promotes `:backlog` → `:todo` (never `:in_progress` alone),
  and enqueues a wake / poll so the dispatcher can claim the issue. Called when
  an agent in that company transitions to `:idle` so newly-available capacity is
  utilised immediately.
  """
  @spec reassign_backlog(binary() | nil) :: {:ok, non_neg_integer(), non_neg_integer()}
  def reassign_backlog(company_id)

  def reassign_backlog(company_id) when is_binary(company_id) do
    backlog_issues =
      Issue
      |> where(
        [i],
        i.status == :backlog and is_nil(i.assignee_id) and i.company_id == ^company_id
      )
      |> Repo.all()

    {assigned, queued} =
      Enum.reduce(backlog_issues, {0, 0}, fn issue, {a, q} ->
        case assign_and_promote_for_dispatch(issue) do
          {:ok, prepared} ->
            _ = enqueue_reassign_wake(prepared)
            {a + 1, q}

          {:error, :no_eligible_agent, _} ->
            {a, q + 1}
        end
      end)

    {:ok, assigned, queued}
  end

  # Fail-closed: unscoped reassignment is a no-op (never scan every tenant).
  def reassign_backlog(_company_id), do: {:ok, 0, 0}

  defp enqueue_reassign_wake(%Issue{} = issue) do
    # Use allowlisted reason `manual_dispatch` (same family as demand-backed hire).
    case Cympho.Orchestrator.Dispatcher.enqueue_wake(issue.id, "manual_dispatch", %{
           "source" => "auto_assignment_reassign",
           "agent_id" => issue.assignee_id
         }) do
      {:ok, _} = ok ->
        ok

      other ->
        # Wake queue may be down; still nudge the dispatcher poll so :todo work
        # is not stranded until the next 30s tick.
        _ = Cympho.Orchestrator.Dispatcher.poll_now()
        other
    end
  end

  @doc """
  Assigns unowned waiting issues for a specific role without starting them.

  Staffing-gap hire flows use this after a new agent is created. It connects
  visible queued work to the new owner immediately, while preserving the issue's
  current board state until runtime dispatch is explicitly started.
  """
  @spec assign_waiting_role_work(binary() | nil, atom() | String.t()) ::
          {:ok, non_neg_integer(), non_neg_integer()}
  def assign_waiting_role_work(company_id, role) do
    with {:ok, assigned_issues, queued} <- assign_waiting_role_work_with_issues(company_id, role) do
      {:ok, length(assigned_issues), queued}
    end
  end

  @doc """
  Assigns unowned waiting issues for a specific role and returns the assigned issues.

  Use this when the caller needs to enqueue wakes or render exact assignment
  receipts after a staffing action.
  """
  @spec assign_waiting_role_work_with_issues(binary() | nil, atom() | String.t()) ::
          {:ok, [Issue.t()], non_neg_integer()}
  def assign_waiting_role_work_with_issues(company_id, role)

  def assign_waiting_role_work_with_issues(company_id, role) when is_binary(company_id) do
    case Agent.normalize_role(role) do
      nil ->
        {:ok, [], 0}

      normalized_role ->
        waiting_issues =
          Issue
          |> where(
            [i],
            i.company_id == ^company_id and i.status in ^@waiting_owner_statuses and
              is_nil(i.assignee_id) and is_nil(i.hidden_at)
          )
          |> Repo.all()
          |> Enum.filter(&(Router.infer_role(&1) == normalized_role))

        {assigned_issues, queued} =
          Enum.reduce(waiting_issues, {[], 0}, fn issue, {assigned, q} ->
            case assign_owner_for_dispatch(issue) do
              {:ok, assigned_issue} -> {[assigned_issue | assigned], q}
              {:error, :no_eligible_agent, _} -> {assigned, q + 1}
            end
          end)

        {:ok, Enum.reverse(assigned_issues), queued}
    end
  end

  # Fail-closed: no company scope → no cross-tenant waiting-work scan.
  def assign_waiting_role_work_with_issues(_company_id, _role), do: {:ok, [], 0}

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
