defmodule CymphoWeb.IssueLive.Show.RunProgress do
  @moduledoc false
  import Ecto.Query

  alias Cympho.Companies.CompanyMembership
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.Issues.Issue
  alias Cympho.Repo

  @stale_seconds 60

  # Only operational fields cross this boundary, never run transcripts or metadata.
  def load(user_id, company_id, issue_id, previous \\ nil) do
    run =
      Repo.one(
        from r in Run,
          join: i in Issue,
          on: i.id == r.issue_id and i.company_id == r.company_id,
          join: m in CompanyMembership,
          on: m.company_id == i.company_id and m.user_id == ^user_id,
          where: i.id == ^issue_id and i.company_id == ^company_id,
          order_by: [
            asc:
              fragment(
                "CASE WHEN ? = ? AND ? = 'running' THEN 0 ELSE 1 END",
                r.id,
                i.checkout_run_id,
                r.status
              ),
            desc: r.inserted_at,
            desc_nulls_last: r.started_at,
            desc_nulls_last: r.completed_at,
            desc: r.id
          ],
          limit: 1,
          select: %{
            run_id: r.id,
            status: r.status,
            started_at: r.started_at,
            completed_at: r.completed_at
          }
      )

    sample =
      if run && run.status == "running" && previous && previous.run_id == run.run_id,
        do: previous.sample

    if run, do: run |> Map.put(:sample, sample) |> Map.put(:checked_at, DateTime.utc_now())
  end

  def accept(%{status: "running"} = state, payload) when is_map(payload) do
    now = DateTime.utc_now()

    with true <- payload[:run_id] == state.run_id,
         true <- CymphoWeb.Events.valid_progress_counters?(payload),
         timestamp when is_binary(timestamp) <- payload[:timestamp],
         {:ok, at, 0} <- DateTime.from_iso8601(timestamp),
         age when age >= -5 and age < @stale_seconds <- DateTime.diff(now, at),
         true <- is_nil(state.started_at) or DateTime.compare(at, state.started_at) != :lt,
         true <- newer_sample?(state.sample, payload, at) do
      %{state | sample: %{bytes: payload.bytes, chunks: payload.chunks, at: at}}
    else
      _ -> state
    end
  end

  def accept(state, _payload), do: state

  defp newer_sample?(nil, _payload, _at), do: true

  defp newer_sample?(sample, payload, at) do
    DateTime.compare(at, sample.at) == :gt and
      payload.bytes >= sample.bytes and payload.chunks >= sample.chunks
  end

  def presentation(nil), do: %{label: "No run yet", detail: "Progress unavailable", elapsed: nil}

  def presentation(state) do
    now = DateTime.utc_now()
    last_activity = if state.sample, do: state.sample.at, else: state.started_at
    stale? = is_nil(last_activity) or DateTime.diff(now, last_activity) >= @stale_seconds

    {label, detail} =
      case state.status do
        "running" when stale? -> {"Activity unavailable", "Run may still be running"}
        "running" when not is_nil(state.sample) -> {"Running", "Output activity"}
        "running" -> {"Running", "Waiting for activity"}
        status when status in ["completed", "succeeded"] -> {"Completed", "Run finished"}
        "failed" -> {"Failed", "Run stopped"}
        "cancelled" -> {"Cancelled", "Run stopped"}
        "timed_out" -> {"Timed out", "Run stopped"}
        status when status in ["pending", "queued"] -> {"Queued", "Not executing yet"}
        _ -> {"Progress unavailable", "Run state unavailable"}
      end

    elapsed =
      if state.started_at do
        finish = state.completed_at || now
        DateTime.diff(finish, state.started_at) |> max(0) |> min(9_007_199_254_740_991)
      end

    %{label: label, detail: detail, elapsed: elapsed}
  end
end
