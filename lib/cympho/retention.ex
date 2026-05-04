defmodule Cympho.Retention do
  @moduledoc """
  Periodic prune jobs that bound the size of high-volume tables.

  Default cutoffs:
    - tool_call_traces: 90 days
    - issue_activities: 180 days
    - governance_audit_logs: 1825 days (5 years; regulatory floor)

  Each prune is a single bulk DELETE indexed on `inserted_at`. Logged at
  `:info` with the row count for observability.
  """

  import Ecto.Query, warn: false
  alias Cympho.Repo
  require Logger

  @tool_call_traces_days 90
  @activities_days 180
  @audit_logs_days 1_825

  @doc "Quantum entrypoint for daily retention sweep."
  def run_all do
    prune_tool_call_traces()
    prune_activities()
    prune_audit_logs()
    :ok
  end

  def prune_tool_call_traces(days \\ @tool_call_traces_days) do
    cutoff = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

    {count, _} =
      Repo.delete_all(from t in "tool_call_traces", where: t.inserted_at < ^cutoff)

    Logger.info("[Retention] pruned tool_call_traces older than #{days} days: #{count} rows")
    {:ok, count}
  end

  def prune_activities(days \\ @activities_days) do
    cutoff = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

    {count, _} =
      Repo.delete_all(from a in "issue_activities", where: a.inserted_at < ^cutoff)

    Logger.info("[Retention] pruned issue_activities older than #{days} days: #{count} rows")
    {:ok, count}
  end

  def prune_audit_logs(days \\ @audit_logs_days) do
    cutoff = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

    {count, _} =
      Repo.delete_all(from l in "governance_audit_logs", where: l.inserted_at < ^cutoff)

    Logger.info("[Retention] pruned governance_audit_logs older than #{days} days: #{count} rows")
    {:ok, count}
  end
end
