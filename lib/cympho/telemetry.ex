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
      [:cympho, :web, :request, :stop]
    ]

    :telemetry.attach_many("cympho-metrics", events, &handle_event/4, nil)
  end

  def issue_created(issue) do
    :telemetry.execute(
      [:cympho, :issue, :created],
      %{count: 1},
      %{status: issue.status, priority: issue.priority, project_id: issue.project_id}
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

  defp handle_event(_event_name, measurements, metadata, _config) do
    :telemetry.execute(
      [:cympho, :event, :logged],
      measurements,
      metadata
    )
  end
end
