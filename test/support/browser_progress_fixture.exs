# Private file-triggered local process fixture, never a product route.
defmodule Cympho.BrowserProgressFixture do
  alias Cympho.{Agents, HeartbeatEngine, Issues}
  alias Cympho.Adapters.ProcessAdapter
  alias CymphoWeb.Events

  def start(root, fixtures) do
    company = fixtures.companies["A"]
    {:ok, issue} = Issues.get_company_issue(company.company_id, company.issues["running"])
    {:ok, agent} = Agents.get_agent(issue.assignee_id)
    command = Path.join(root, "bounded-progress.sh")

    File.write!(command, """
    #!/bin/sh
    i=0
    while [ "$i" -lt 15 ]; do
      printf 'PRIVATE_RAW_OUTPUT_SENTINEL\\n'
      /bin/sleep 1
      i=$((i + 1))
    done
    """)

    File.chmod!(command, 0o700)

    {:ok, run} =
      HeartbeatEngine.create_run(%{
        issue_id: issue.id,
        agent_id: agent.id,
        company_id: issue.company_id,
        adapter: "process"
      })

    {:ok, run} = HeartbeatEngine.start_run(run)

    session =
      ProcessAdapter.run(issue, agent.id, self(),
        run_id: run.id,
        budgeted_prompt: "Synthetic bounded progress check",
        config: %{
          "command" => command,
          "prompt_stdin" => false,
          "max_run_ms" => 25_000,
          "timeout" => 5_000
        }
      )

    File.write!(
      Path.join(root, "progress-run.json"),
      Jason.encode!(%{run_id: run.id, issue_id: issue.id, status: run.status})
    )

    %{issue: issue, run: run, session: session, root: root}
  end

  def receive_event(%{session: session} = state) do
    receive do
      {:turn_progress, ^session, progress} ->
        Events.broadcast_run_progress(state.issue, state.run.id, progress)
        state

      {:turn_completed, ^session, _result} ->
        {:ok, run} =
          HeartbeatEngine.complete_run(state.run, %{
            continuation_summary: "Bounded local process completed"
          })

        :ok = Cympho.AdapterSessions.wait_for_exit(session, 2_000)

        File.write!(
          Path.join(state.root, "progress-finished.json"),
          Jason.encode!(%{run_id: run.id, status: run.status})
        )

        nil

      {:turn_ended_with_error, ^session, _reason} ->
        {:ok, _} = HeartbeatEngine.fail_run(state.run, :synthetic_process_failed)
        nil

      {:session_started, ^session} ->
        state
    after
      0 -> state
    end
  end

  def receive_event(nil), do: nil

  def stop(nil), do: :ok

  def stop(state) do
    :ok = Cympho.AdapterSessions.cancel_and_wait(state.session, :fixture_stop, 2_000)
    {:ok, _} = HeartbeatEngine.cancel_run(state.run)
    :ok
  end
end
