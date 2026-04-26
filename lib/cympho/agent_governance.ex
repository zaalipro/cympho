defmodule Cympho.AgentGovernance do
  @moduledoc """
  Agent governance controls for pause/resume/terminate with approval requirements.
  """

  import Ecto.Query, warn: false
  alias Cympho.Repo
  alias Cympho.Agents.Agent
  alias Cympho.BoardApprovals
  alias Cympho.GovernanceAuditLogs
  alias Cympho.Decisions

  @governance_statuses ["active", "paused", "terminated", "pending_approval"]

  @doc """
  Pauses an agent with optional approval requirement.
  """
  def pause_agent(agent_id, opts \\ %{}, actor) do
    agent = Repo.get!(Agent, agent_id)
    requires_approval = Keyword.get(opts, :requires_board_approval, false)

    if requires_approval do
      request_board_approval_for_pause(agent, opts, actor)
    else
      do_pause_agent(agent, opts, actor)
    end
  end

  @doc """
  Resumes a paused agent.
  """
  def resume_agent(agent_id, reason, actor) do
    agent = Repo.get!(Agent, agent_id)

    if agent.governance_status == "paused" do
      agent
      |> Ecto.Changeset.change(%{
        governance_status: "active",
        governance_reasoning: reason,
        paused_at: nil,
        paused_by_user_id: nil
      })
      |> Repo.update()
      |> case do
        {:ok, updated} ->
          GovernanceAuditLogs.log_action(
            "agent_resumed",
            actor,
            "Agent resumed: #{updated.name}",
            resource: updated,
            reasoning: reason
          )

          Decisions.record_governance_decision(updated, "resume", "approved", actor)

          Phoenix.PubSub.broadcast(Cympho.PubSub, "company:#{updated.company_id}:agents", {:agent_resumed, updated})
          {:ok, updated}

        error ->
          error
      end
    else
      {:error, :not_paused}
    end
  end

  @doc """
  Terminates an agent with board approval requirement.
  """
  def terminate_agent(agent_id, reason, opts \\ %{}, actor) do
    agent = Repo.get!(Agent, agent_id)
    requires_approval = Keyword.get(opts, :requires_board_approval, true)

    if requires_approval do
      request_board_approval_for_termination(agent, reason, actor)
    else
      do_terminate_agent(agent, reason, actor)
    end
  end

  @doc """
  Checks if an agent action requires governance approval.
  """
  def requires_approval?(%Agent{} = agent, action) do
    agent.governance_status != "active" or
      agent.requires_board_approval or
      sensitive_action?(action)
  end

  @doc """
  Lists agents by governance status.
  """
  def list_agents_by_status(status) when status in @governance_statuses do
    from(a in Agent, where: a.governance_status == ^status)
    |> Repo.all()
  end

  def list_agents_by_status(_), do: []

  @doc """
  Subscribes to agent governance events.
  """
  def subscribe(company_id) do
    Phoenix.PubSub.subscribe(Cympho.PubSub, "company:#{company_id}:agents")
  end

  defp request_board_approval_for_pause(agent, opts, actor) do
    board_approval_attrs = %{
      title: "Pause Agent: #{agent.name}",
      description: Keyword.get(opts, :reason, "Agent pause requested"),
      category: "agent_termination",
      proposal_data: %{
        "agent_id" => agent.id,
        "action" => "pause",
        "current_status" => agent.governance_status
      },
      requested_by_agent_id: Map.get(actor, :id) || elem(actor, 1),
      company_id: agent.company_id,
      review_deadline: Keyword.get(opts, :review_deadline, DateTime.add(DateTime.utc_now(), 7 * 24 * 3600, :second))
    }

    case BoardApprovals.create_board_approval(board_approval_attrs, actor) do
      {:ok, approval} ->
        agent
        |> Ecto.Changeset.change(%{
          governance_status: "pending_approval",
          board_approval_id: approval.id
        })
        |> Repo.update()

        {:ok, :pending_approval, approval}

      error ->
        error
    end
  end

  defp request_board_approval_for_termination(agent, reason, actor) do
    board_approval_attrs = %{
      title: "Terminate Agent: #{agent.name}",
      description: reason,
      category: "agent_termination",
      proposal_data: %{
        "agent_id" => agent.id,
        "action" => "terminate",
        "current_status" => agent.governance_status
      },
      requested_by_agent_id: Map.get(actor, :id) || elem(actor, 1),
      company_id: agent.company_id,
      review_deadline: DateTime.add(DateTime.utc_now(), 7 * 24 * 3600, :second)
    }

    case BoardApprovals.create_board_approval(board_approval_attrs, actor) do
      {:ok, approval} ->
        agent
        |> Ecto.Changeset.change(%{
          governance_status: "pending_approval",
          board_approval_id: approval.id
        })
        |> Repo.update()

        {:ok, :pending_approval, approval}

      error ->
        error
    end
  end

  defp do_pause_agent(agent, opts, actor) do
    agent
    |> Ecto.Changeset.change(%{
      governance_status: "paused",
      governance_reasoning: Keyword.get(opts, :reason),
      paused_at: DateTime.utc_now(),
      paused_by_user_id: extract_user_id(actor)
    })
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        GovernanceAuditLogs.log_action(
          "agent_paused",
          actor,
          "Agent paused: #{updated.name}",
          resource: updated,
          reasoning: Keyword.get(opts, :reason)
        )

        Decisions.record_governance_decision(updated, "pause", "approved", actor)

        Phoenix.PubSub.broadcast(Cympho.PubSub, "company:#{updated.company_id}:agents", {:agent_paused, updated})
        {:ok, updated}

      error ->
        error
    end
  end

  defp do_terminate_agent(agent, reason, actor) do
    agent
    |> Ecto.Changeset.change(%{
      governance_status: "terminated",
      governance_reasoning: reason
    })
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        GovernanceAuditLogs.log_action(
          "agent_terminated",
          actor,
          "Agent terminated: #{updated.name}",
          resource: updated,
          reasoning: reason
        )

        Decisions.record_governance_decision(updated, "terminate", "approved", actor)

        Phoenix.PubSub.broadcast(Cympho.PubSub, "company:#{updated.company_id}:agents", {:agent_terminated, updated})
        {:ok, updated}

      error ->
        error
    end
  end

  defp sensitive_action?(action) when action in [
    :delete_data,
    :modify_permissions,
    :access_sensitive_resources,
    :bulk_operations
  ], do: true

  defp sensitive_action?(_), do: false

  defp extract_user_id(%{id: id}) when is_binary(id), do: id
  defp extract_user_id({_, id}) when is_binary(id), do: id
  defp extract_user_id(_), do: nil
end
