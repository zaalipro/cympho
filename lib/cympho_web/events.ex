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
  alias Cympho.Agents.Agent

  def broadcast_issue_update(%Issue{company_id: company_id, id: issue_id} = issue, event_type, metadata \\ %{}) do
    topic = "company:#{company_id}:issues"
    payload = build_event_payload(event_type, issue_id, metadata, issue)
    CymphoWeb.Endpoint.broadcast(topic, "issue_update", payload)
  end

  def broadcast_comment(%Comment{issue_id: issue_id} = comment, event_type \\ :comment_created) do
    case Repo.get(Issue, issue_id) do
      nil -> :ok
      %Issue{company_id: company_id, project_id: project_id} ->
        topic = "company:#{company_id}:project:#{project_id}:comments"
        payload = build_comment_payload(comment, event_type)
        CymphoWeb.Endpoint.broadcast(topic, "comment", payload)
    end
  end

  def broadcast_run_status(%Run{id: run_id, issue_id: issue_id, agent_id: agent_id, status: new_status} = run, event_type, old_status \\ nil) do
    case Repo.get(Issue, issue_id) do
      nil -> :ok
      %Issue{company_id: company_id} ->
        topic = "company:#{company_id}:runs"
        payload = build_run_payload(run, event_type, old_status)
        Phoenix.PubSub.broadcast(Cympho.PubSub, topic, {:run_status_changed, payload})
    end
  end

  def broadcast_agent_heartbeat(%Issue{company_id: company_id, id: issue_id}, agent_id, heartbeat_data) do
    topic = "company:#{company_id}:issues:#{issue_id}:heartbeats"
    payload = %{
      event_type: :agent_heartbeat,
      agent_id: agent_id,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      data: heartbeat_data
    }
    CymphoWeb.Endpoint.broadcast(topic, "heartbeat", payload)
  end

  def subscribe_to_issues(company_id) do
    Phoenix.PubSub.subscribe(Cympho.PubSub, "company:#{company_id}:issues")
  end

  def subscribe_to_comments(company_id) do
    Phoenix.PubSub.subscribe(Cympho.PubSub, "company:#{company_id}:comments")
  end

  def subscribe_to_runs(company_id) do
    Phoenix.PubSub.subscribe(Cympho.PubSub, "company:#{company_id}:runs")
  end

  def subscribe_to_heartbeats(issue_id) do
    Phoenix.PubSub.subscribe(Cympho.PubSub, "issue:#{issue_id}:heartbeats")
  end

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

  defp build_comment_payload(%Comment{id: comment_id, issue_id: issue_id, body: body, author_id: author_id, author_type: author_type}, event_type) do
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

  defp build_run_payload(%Run{id: run_id, status: new_status, adapter: adapter, issue_id: issue_id, agent_id: agent_id}, event_type, old_status) do
    %{
      run_id: run_id,
      issue_id: issue_id,
      agent_id: agent_id,
      old_status: old_status,
      new_status: new_status,
      event_type: event_type,
      adapter: adapter,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end
end
