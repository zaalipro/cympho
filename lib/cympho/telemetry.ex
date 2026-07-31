defmodule Cympho.Telemetry do
  @moduledoc false

  def setup do
    events = [
      [:cympho, :issue, :created],
      [:cympho, :issue, :updated],
      [:cympho, :issue, :deleted],
      [:cympho, :issue, :transitioned],
      [:cympho, :agent, :heartbeat],
      [:cympho, :agent, :assigned],
      [:cympho, :agent, :status_changed],
      [:cympho, :kanban, :card_moved],
      [:cympho, :command_palette, :opened],
      [:cympho, :onboarding, :completed],
      [:cympho, :web, :request, :stop],
      [:cympho, :tool, :call],
      [:cympho, :tool, :complete],
      [:cympho, :routing, :classified],
      [:cympho, :run, :lifecycle],
      [:cympho, :dispatcher, :dispatch],
      [:cympho, :dispatcher, :stalled_wakeup]
    ]

    :telemetry.attach_many("cympho-metrics", events, &handle_event/4, nil)
  end

  def issue_created(issue) do
    :telemetry.execute(
      [:cympho, :issue, :created],
      %{count: 1},
      %{
        issue_id: issue.id,
        company_id: issue.company_id,
        project_id: issue.project_id,
        status: issue.status,
        priority: issue.priority
      }
    )
  end

  def issue_transitioned(issue, from_status, to_status) do
    :telemetry.execute(
      [:cympho, :issue, :transitioned],
      %{count: 1},
      %{from: from_status, to: to_status, issue_id: issue.id}
    )
  end

  def agent_assigned(agent_id, issue_id) do
    :telemetry.execute(
      [:cympho, :agent, :assigned],
      %{count: 1},
      %{agent_id: agent_id, issue_id: issue_id}
    )
  end

  def agent_status_changed(agent_id, from, to) do
    :telemetry.execute(
      [:cympho, :agent, :status_changed],
      %{count: 1},
      %{agent_id: agent_id, from: from, to: to}
    )
  end

  def kanban_card_moved(issue_id, from, to) do
    :telemetry.execute(
      [:cympho, :kanban, :card_moved],
      %{count: 1},
      %{issue_id: issue_id, from: from, to: to}
    )
  end

  def command_palette_opened do
    :telemetry.execute([:cympho, :command_palette, :opened], %{count: 1}, %{})
  end

  def onboarding_completed do
    :telemetry.execute([:cympho, :onboarding, :completed], %{count: 1}, %{})
  end

  def run_lifecycle(run, action) when is_map(run) do
    :telemetry.execute(
      [:cympho, :run, :lifecycle],
      %{count: 1, duration_ms: run_duration_ms(run)},
      %{
        action: action,
        run_id: Map.get(run, :id),
        company_id: Map.get(run, :company_id),
        agent_id: Map.get(run, :agent_id),
        issue_id: Map.get(run, :issue_id),
        status: Map.get(run, :status),
        adapter: Map.get(run, :adapter)
      }
    )
  end

  def dispatch_started(issue, agent_id, role) do
    :telemetry.execute(
      [:cympho, :dispatcher, :dispatch],
      %{count: 1},
      %{
        status: :started,
        company_id: Map.get(issue, :company_id),
        issue_id: Map.get(issue, :id),
        agent_id: agent_id,
        role: role
      }
    )
  end

  def dispatch_retry_scheduled(issue, attempt, backoff_ms) do
    :telemetry.execute(
      [:cympho, :dispatcher, :dispatch],
      %{count: 1, attempt: attempt, backoff_ms: backoff_ms},
      %{
        status: :retry_scheduled,
        company_id: Map.get(issue, :company_id),
        issue_id: Map.get(issue, :id),
        role: Map.get(issue, :assigned_role)
      }
    )
  end

  defp run_duration_ms(%{
         started_at: %DateTime{} = started_at,
         completed_at: %DateTime{} = completed_at
       }) do
    max(DateTime.diff(completed_at, started_at, :millisecond), 0)
  end

  defp run_duration_ms(_), do: 0

  defp handle_event(_event_name, measurements, metadata, _config) do
    :telemetry.execute(
      [:cympho, :event, :logged],
      measurements,
      metadata
    )
  end
end
