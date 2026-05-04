defmodule CymphoWeb.Events do
  @moduledoc """
  Real-time event broadcasting for Cympho.

  Broadcasts structured events to Phoenix Channels for:
  - Issue updates
  - Comment notifications
  - Run status changes
  - Agent heartbeats

  Events are scoped by company and optionally by project/issue.
  Integrates with existing PubSub broadcasts to WebSocket clients.
  """

  alias Cympho.Repo
  alias Cympho.Issues.Issue
  alias Cympho.Comments.Comment
  alias Cympho.HeartbeatEngine.Run

  @doc """
  Broadcast an issue update event to WebSocket clients.

  ## Event Types
  - :issue_created - New issue created
  - :issue_updated - Issue attributes changed
  - :issue_status_changed - Issue status transitioned
  - :issue_assigned - Issue assigned to agent
  - :issue_blocked - Issue marked as blocked
  - :issue_unblocked - Issue unblocked
  - :issue_deleted - Issue deleted

  ## Examples
      Events.broadcast_issue_update(issue, :issue_updated)
      Events.broadcast_issue_update(issue, :issue_status_changed, %{from: :todo, to: :in_progress})
  """
  def broadcast_issue_update(
        %Issue{company_id: company_id, id: issue_id} = issue,
        event_type,
        metadata \\ %{}
      ) do
    topic = "company:#{company_id}:issues"
    payload = build_event_payload(event_type, issue_id, metadata, issue)

    Cympho.RateLimiting.dedup_broadcast(topic, "issue_update", payload)
  end

  @doc """
  Broadcast a comment notification to WebSocket clients.
  """
  def broadcast_comment(%Comment{issue_id: issue_id} = comment, event_type \\ :comment_created) do
    case Repo.get(Issue, issue_id) do
      nil ->
        :ok

      %Issue{company_id: company_id, project_id: project_id} ->
        topic = "company:#{company_id}:project:#{project_id}:comments"
        payload = build_comment_payload(comment, event_type)
        Cympho.RateLimiting.dedup_broadcast(topic, "comment", payload)
    end
  end

  @doc """
  Broadcast a run status change to WebSocket clients.
  """
  def broadcast_run_status(%Run{id: _run_id, issue_id: issue_id} = run, event_type) do
    case Repo.get(Issue, issue_id) do
      nil ->
        :ok

      %Issue{company_id: company_id} ->
        topic = "company:#{company_id}:runs"
        payload = build_run_payload(run, event_type)
        Cympho.RateLimiting.dedup_broadcast(topic, "run_status", payload)
    end
  end

  @doc """
  Broadcast an agent heartbeat event to WebSocket clients.
  """
  def broadcast_agent_heartbeat(
        %Issue{company_id: company_id, id: issue_id},
        agent_id,
        heartbeat_data
      ) do
    topic = "company:#{company_id}:issues:#{issue_id}:heartbeats"

    payload = %{
      event_type: :agent_heartbeat,
      agent_id: agent_id,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      data: heartbeat_data
    }

    Cympho.RateLimiting.dedup_broadcast(topic, "heartbeat", payload)
  end

  @doc """
  Subscribe to issue events for a company via PubSub (for LiveView).
  """
  def subscribe_to_issues(company_id) do
    Phoenix.PubSub.subscribe(Cympho.PubSub, "company:#{company_id}:issues")
  end

  @doc """
  Subscribe to comment events for a project via PubSub (for LiveView).
  """
  def subscribe_to_comments(company_id) do
    Phoenix.PubSub.subscribe(Cympho.PubSub, "company:#{company_id}:comments")
  end

  @doc """
  Subscribe to run status events for a company via PubSub (for LiveView).
  """
  def subscribe_to_runs(company_id) do
    Phoenix.PubSub.subscribe(Cympho.PubSub, "company:#{company_id}:runs")
  end

  @doc """
  Subscribe to heartbeat events for a specific issue via PubSub (for LiveView).
  """
  def subscribe_to_heartbeats(issue_id) do
    Phoenix.PubSub.subscribe(Cympho.PubSub, "issue:#{issue_id}:heartbeats")
  end

  # Private helpers

  defp build_event_payload(event_type, resource_id, metadata, %Issue{} = issue) do
    base = %{
      event_type: event_type,
      resource_id: resource_id,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    issue_data = %{
      title: issue.title,
      status: issue.status,
      priority: issue.priority,
      identifier: issue.identifier,
      assignee_id: issue.assignee_id,
      project_id: issue.project_id
    }

    Map.merge(base, Map.merge(metadata, issue_data))
  end

  defp build_comment_payload(
         %Comment{
           id: comment_id,
           issue_id: issue_id,
           body: body,
           author_id: author_id,
           author_type: author_type
         },
         event_type
       ) do
    %{
      event_type: event_type,
      resource_id: comment_id,
      issue_id: issue_id,
      content: String.slice(body, 0, 200),
      author_id: author_id,
      author_type: author_type,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp build_run_payload(
         %Run{id: run_id, status: status, adapter: adapter, issue_id: issue_id},
         event_type
       ) do
    %{
      event_type: event_type,
      resource_id: run_id,
      issue_id: issue_id,
      status: status,
      adapter: adapter,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end
end
