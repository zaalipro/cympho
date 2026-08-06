defmodule Cympho.Issues.RehomePaused do
  @moduledoc """
  Rehomes non-terminal work off a paused (or otherwise dead) agent.

  `Agents.pause_agent/2` only flips status metadata — without this helper,
  todo / in_progress / in_review / blocked issues stay pinned to an agent
  that can no longer run them. We clear the assignee (and checkout for
  in-flight work), cancel their wakes, and poke manager + dispatch so the
  fleet can reclaim the work.
  """

  import Ecto.Query, warn: false

  alias Cympho.Agents
  alias Cympho.Agents.Agent
  alias Cympho.Issues
  alias Cympho.Issues.Issue
  alias Cympho.Orchestrator.Dispatcher
  alias Cympho.Repo
  alias Cympho.Wakes

  require Logger

  @non_terminal_statuses [:backlog, :todo, :in_progress, :in_review, :blocked]

  @doc """
  Rehomes every non-terminal issue currently assigned to `agent`.

  Steps per issue:
    1. `force_release_issue` clears assignee + checkout, preserving blocked /
       in_review / backlog status when applicable (else `:todo`)
    2. cancel any remaining pending/running wakes for the paused agent
    3. wake the agent's manager (parent, else company CEO) once for the issue
    4. enqueue a dispatch poll via `Dispatcher.enqueue_wake` so unassigned
       work can be claimed

  Returns `{:ok, summary}` where summary is:

      %{
        rehomed: [Issue.t()],
        cancelled_wakes: non_neg_integer(),
        manager_wakes: non_neg_integer(),
        dispatch_nudges: non_neg_integer()
      }
  """
  @spec rehome_for_paused_agent(Agent.t() | String.t(), keyword()) ::
          {:ok, map()} | {:error, atom()}
  def rehome_for_paused_agent(agent_or_id, opts \\ [])

  def rehome_for_paused_agent(agent_id, opts) when is_binary(agent_id) do
    case Agents.get_agent(agent_id) do
      {:ok, agent} -> rehome_for_paused_agent(agent, opts)
      error -> error
    end
  end

  def rehome_for_paused_agent(%Agent{} = agent, opts) do
    reason = Keyword.get(opts, :reason) || agent.pause_reason || "Agent paused"

    issues = list_rehomeable_issues(agent.id)

    rehomed =
      issues
      |> Enum.map(&rehome_issue(&1, agent, reason))
      |> Enum.reject(&is_nil/1)

    {:ok, cancelled_wakes} = Wakes.cancel_agent_wakes(agent.id, reason)

    {manager_wakes, dispatch_nudges} =
      Enum.reduce(rehomed, {0, 0}, fn issue, {mw, dn} ->
        mw_inc = maybe_wake_manager(agent, issue, reason)
        dn_inc = maybe_nudge_dispatch(issue, agent, reason)
        {mw + mw_inc, dn + dn_inc}
      end)

    if rehomed != [] do
      Logger.info(
        "rehomed paused-agent work",
        agent_id: agent.id,
        company_id: agent.company_id,
        rehomed: length(rehomed),
        cancelled_wakes: cancelled_wakes,
        component: "rehome_paused"
      )
    end

    {:ok,
     %{
       rehomed: rehomed,
       cancelled_wakes: cancelled_wakes,
       manager_wakes: manager_wakes,
       dispatch_nudges: dispatch_nudges
     }}
  end

  @doc """
  Non-terminal issues currently assigned to the agent (rehome candidates).
  """
  @spec list_rehomeable_issues(String.t()) :: [Issue.t()]
  def list_rehomeable_issues(agent_id) when is_binary(agent_id) do
    from(i in Issue,
      where:
        i.assignee_id == ^agent_id and i.status in ^@non_terminal_statuses and
          is_nil(i.hidden_at),
      order_by: [asc: i.updated_at]
    )
    |> Repo.all()
  end

  def list_rehomeable_issues(_), do: []

  defp rehome_issue(%Issue{} = issue, %Agent{} = agent, reason) do
    target = release_target_status(issue.status)

    case Issues.force_release_issue(issue, target) do
      {:ok, released} ->
        _ =
          Cympho.Activities.log_activity(%{
            issue_id: released.id,
            company_id: released.company_id,
            actor_type: "system",
            action: "rehomed_on_pause",
            metadata: %{
              previous_assignee_id: agent.id,
              previous_status: to_string(issue.status),
              target_status: to_string(target),
              reason: reason
            }
          })

        released

      {:error, reason} ->
        Logger.warning(
          "failed to rehome issue on agent pause",
          issue_id: issue.id,
          agent_id: agent.id,
          reason: inspect(reason),
          component: "rehome_paused"
        )

        nil
    end
  end

  defp release_target_status(:blocked), do: :blocked
  defp release_target_status(:in_review), do: :in_review
  defp release_target_status(:backlog), do: :backlog
  defp release_target_status(_), do: :todo

  defp maybe_wake_manager(%Agent{} = agent, %Issue{} = issue, reason) do
    case resolve_manager(agent) do
      %Agent{id: manager_id} ->
        case Wakes.wake_for_assignee_paused(manager_id, issue.id, %{
               "paused_agent_id" => agent.id,
               "paused_agent_name" => agent.name,
               "previous_status" => to_string(issue.status),
               "reason" => reason,
               "company_id" => issue.company_id
             }) do
          {:ok, _} -> 1
          {:error, _} -> 0
        end

      nil ->
        0
    end
  end

  defp maybe_nudge_dispatch(%Issue{} = issue, %Agent{} = agent, reason) do
    case Dispatcher.enqueue_wake(issue.id, "agent_paused_rehome", %{
           "previous_assignee_id" => agent.id,
           "reason" => reason
         }) do
      {:ok, _} -> 1
      {:error, _} -> 0
    end
  end

  defp resolve_manager(%Agent{parent_id: parent_id}) when is_binary(parent_id) do
    case Agents.get_agent(parent_id) do
      {:ok, %Agent{} = parent} ->
        if agent_awakeable?(parent), do: parent, else: ceo_for(parent.company_id)

      _ ->
        nil
    end
  end

  defp resolve_manager(%Agent{company_id: company_id}), do: ceo_for(company_id)

  defp ceo_for(nil), do: nil

  defp ceo_for(company_id) when is_binary(company_id) do
    case Agents.get_company_ceo(company_id) do
      {:ok, %Agent{} = ceo} ->
        if agent_awakeable?(ceo), do: ceo, else: nil

      _ ->
        nil
    end
  end

  defp agent_awakeable?(%Agent{status: status}) when status in [:paused, :terminated], do: false

  defp agent_awakeable?(%Agent{governance_status: status})
       when status in ["paused", "terminated", "pending_approval"],
       do: false

  defp agent_awakeable?(%Agent{}), do: true
end
