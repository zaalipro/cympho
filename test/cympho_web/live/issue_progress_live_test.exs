defmodule CymphoWeb.IssueProgressLiveTest do
  use CymphoWeb.LiveCase, async: true

  alias Cympho.{Agents, Companies, HeartbeatEngine, Issues, Repo}
  alias Cympho.HeartbeatEngine.Run
  alias CymphoWeb.Events
  alias CymphoWeb.IssueLive.Show.RunProgress

  setup do
    {:ok, issue} =
      Issues.create_issue(scoped_attrs(%{title: "Safe progress", status: :in_progress}))

    {:ok, agent} = Agents.create_agent(scoped_attrs(%{name: "Progress agent", role: :engineer}))
    run = insert_run(issue, agent)
    %{issue: issue, agent: agent, run: run}
  end

  test "renders active counters but never arbitrary event content", %{issue: issue, run: run} do
    {:ok, view, _} = live(conn(), "/issues/#{issue.id}")
    assert progress(view) =~ "Running"
    assert progress(view) =~ "Waiting for activity"

    Events.broadcast_run_progress(issue, run.id, %{
      bytes: 2048,
      chunks: 7,
      stdout: "RAW_SENTINEL",
      reasoning: "REASONING_SENTINEL",
      prompt: "PROMPT_SENTINEL",
      secret: "SECRET_SENTINEL"
    })

    assert progress(view) =~ "2048 bytes"
    assert progress(view) =~ "7 chunks"
    assert progress(view) =~ "Output activity"
    assert progress(view) =~ "Elapsed"

    send_progress(view, issue, run, %{
      bytes: 2049,
      chunks: 8,
      metadata: %{secret: "SECRET_SENTINEL"},
      stdout: "RAW_SENTINEL",
      reasoning: "REASONING_SENTINEL",
      prompt: "PROMPT_SENTINEL"
    })

    assert progress(view) =~ "2049 bytes"

    for sentinel <- ~w(RAW_SENTINEL REASONING_SENTINEL PROMPT_SENTINEL SECRET_SENTINEL),
        do: refute(render(view) =~ sentinel)
  end

  test "adapter error messages do not expose raw diagnostic content", %{issue: issue} do
    {:ok, view, _} = live(conn(), "/issues/#{issue.id}")
    send(view.pid, {:turn_ended_with_error, make_ref(), "PRIVATE_ERROR_SENTINEL"})
    html = render(view)
    refute html =~ "PRIVATE_ERROR_SENTINEL"
    assert html =~ "Agent run failed"
  end

  test "a foreign topic cannot deliver otherwise valid progress", %{issue: issue, run: run} do
    {:ok, view, _} = live(conn(), "/issues/#{issue.id}")

    send(view.pid, %Phoenix.Socket.Broadcast{
      topic: "company:#{Ecto.UUID.generate()}:runs",
      event: "run_progress",
      payload: %{
        company_id: issue.company_id,
        issue_id: issue.id,
        run_id: run.id,
        bytes: 999,
        chunks: 9,
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
      }
    })

    refute progress(view) =~ "999 bytes"
    assert progress(view) =~ "Waiting for activity"
  end

  test "scheduled reconciliation recovers a missed terminal event", %{issue: issue, run: run} do
    {:ok, view, _} = live(conn(), "/issues/#{issue.id}")
    Repo.update!(Ecto.Changeset.change(run, status: "completed"))
    wait_until(fn -> assert progress(view) =~ "Completed" end, 6_000, 100)
  end

  test "ignores foreign nil other-issue and prior-run scope", %{issue: issue, run: run} do
    {:ok, view, _} = live(conn(), "/issues/#{issue.id}")
    send_progress(view, issue, run, %{bytes: 12, chunks: 2})
    before = progress_without_elapsed(view)

    for changes <- [
          %{company_id: Ecto.UUID.generate()},
          %{company_id: nil},
          %{issue_id: Ecto.UUID.generate()},
          %{issue_id: nil},
          %{run_id: Ecto.UUID.generate()},
          %{run_id: nil}
        ] do
      send_progress(view, issue, run, Map.merge(%{bytes: 900, chunks: 99}, changes))
      assert progress_without_elapsed(view) == before
    end
  end

  test "malformed and out-of-order telemetry cannot create activity or crash", %{
    issue: issue,
    run: run
  } do
    {:ok, view, _} = live(conn(), "/issues/#{issue.id}")
    send_progress(view, issue, run, %{bytes: 12, chunks: 2})
    before = progress_without_elapsed(view)

    for changes <- [
          %{bytes: "13"},
          %{chunks: nil},
          %{bytes: -1},
          %{chunks: 1.5},
          %{bytes: 10_000_000_000_000_000_000},
          %{timestamp: "bad"},
          %{timestamp: DateTime.add(DateTime.utc_now(), 60) |> DateTime.to_iso8601()},
          %{timestamp: DateTime.add(DateTime.utc_now(), -120) |> DateTime.to_iso8601()},
          %{bytes: 1, chunks: 1}
        ] do
      send_progress(view, issue, run, Map.merge(%{bytes: 13, chunks: 3}, changes))
      assert progress_without_elapsed(view) == before
    end

    for event <- ["run_progress", "run_status"],
        payload <- [nil, [], "bad", %{}, DateTime.utc_now()] do
      send(view.pid, %Phoenix.Socket.Broadcast{event: event, payload: payload})
      assert progress_without_elapsed(view) == before
    end

    send(view.pid, {:unexpected, "UNEXPECTED_SECRET_SENTINEL"})
    assert progress_without_elapsed(view) == before
  end

  test "older running checkout wins until release then newest tied terminal attempt wins", %{
    issue: issue,
    agent: agent,
    run: run
  } do
    Repo.delete!(run)

    previous =
      Repo.insert!(%Run{
        id: "ffffffff-ffff-4fff-afff-ffffffffffff",
        company_id: issue.company_id,
        issue_id: issue.id,
        agent_id: agent.id,
        status: "running",
        inserted_at: run.inserted_at,
        started_at: run.started_at
      })

    current =
      Repo.insert!(%Run{
        id: "00000000-0000-4000-a000-000000000001",
        company_id: issue.company_id,
        issue_id: issue.id,
        agent_id: agent.id,
        status: "completed",
        inserted_at: run.inserted_at,
        started_at: run.started_at,
        completed_at: run.started_at
      })

    Repo.update!(
      Ecto.Changeset.change(issue,
        checkout_run_id: previous.id,
        assignee_id: agent.id,
        checked_out_at: run.started_at
      )
    )

    {:ok, view, _} = live(conn(), "/issues/#{issue.id}")
    send_progress(view, issue, previous, %{bytes: 44, chunks: 4})
    assert progress(view) =~ "44 bytes"
    assert authoritative_progress(issue).run_id == previous.id
    {:ok, _failed} = HeartbeatEngine.fail_run(previous, :stall_timeout)
    Repo.update!(Ecto.Changeset.change(previous, status: "failed", completed_at: run.started_at))

    assert is_nil(Repo.get!(Issues.Issue, issue.id).checkout_run_id)
    send(view.pid, :refresh_run_progress)
    assert progress(view) =~ "Completed"
    assert authoritative_progress(issue).run_id == current.id
    send_status(view, issue, previous, "failed")
    send_progress(view, issue, previous, %{bytes: 999, chunks: 99})
    assert progress(view) =~ "Completed"
    refute progress(view) =~ "999 bytes"
    {:ok, reconnected, _} = live(conn(), "/issues/#{issue.id}")
    assert progress(reconnected) =~ "Completed"
  end

  for {attempt, retry_count} <- [{"retry", 1}, {"fresh session", 0}] do
    test "direct context #{attempt} wins tied timestamps despite reversed UUID and retry order",
         %{
           issue: issue,
           agent: agent,
           run: run
         } do
      Repo.delete!(run)

      previous =
        Repo.insert!(%Run{
          id: "ffffffff-ffff-4fff-afff-ffffffffffff",
          company_id: issue.company_id,
          issue_id: issue.id,
          agent_id: agent.id,
          status: "failed",
          retry_count: 7,
          inserted_at: run.inserted_at,
          started_at: run.started_at,
          completed_at: run.started_at
        })

      {:ok, current} =
        HeartbeatEngine.create_run(%{
          company_id: issue.company_id,
          issue_id: issue.id,
          agent_id: agent.id,
          adapter: "process"
        })

      current =
        Repo.update!(
          Ecto.Changeset.change(current,
            id: "00000000-0000-4000-a000-000000000001",
            status: "completed",
            retry_count: unquote(retry_count),
            inserted_at: run.inserted_at,
            started_at: run.started_at,
            completed_at: run.started_at
          )
        )

      assert previous.id > current.id
      assert previous.inserted_at == current.inserted_at
      assert previous.started_at == current.started_at
      assert previous.completed_at == current.completed_at
      assert is_nil(Repo.get!(Issues.Issue, issue.id).checkout_run_id)
      assert authoritative_progress(issue).run_id == current.id
      {:ok, view, _} = live(conn(), "/issues/#{issue.id}")
      assert progress(view) =~ "Completed"
      send(view.pid, :refresh_run_progress)
      assert progress(view) =~ "Completed"
      send_status(view, issue, previous, "running")
      send_progress(view, issue, previous, %{bytes: 999, chunks: 99})
      assert progress(view) =~ "Completed"
      refute progress(view) =~ "999 bytes"
      {:ok, remounted, _} = live(conn(), "/issues/#{issue.id}")
      assert progress(remounted) =~ "Completed"
    end
  end

  test "legacy history retains timestamp fallback without invented exact-tie chronology", %{
    issue: issue,
    agent: agent,
    run: run
  } do
    assert is_integer(Map.get(run, :creation_ordinal))

    previous =
      Repo.update!(
        Ecto.Changeset.change(run,
          creation_ordinal: nil,
          status: "failed",
          completed_at: run.started_at
        )
      )

    current = insert_run(issue, agent, DateTime.add(run.inserted_at, 2))

    current =
      Repo.update!(
        Ecto.Changeset.change(current,
          creation_ordinal: nil,
          status: "completed",
          started_at: run.started_at,
          completed_at: run.started_at
        )
      )

    assert authoritative_progress(issue).run_id == current.id
    # Legacy fallback is deterministic, not recovered creation chronology.
    expected_id = max(previous.id, current.id)
    Repo.update!(Ecto.Changeset.change(current, inserted_at: previous.inserted_at))
    assert authoritative_progress(issue).run_id == expected_id

    newer = insert_run(issue, agent, DateTime.add(run.inserted_at, -2))
    assert authoritative_progress(issue).run_id == newer.id
  end

  test "malformed run scope in persistence cannot supply progress", %{issue: issue, run: run} do
    Repo.update!(Ecto.Changeset.change(run, company_id: nil))
    {:ok, view, _} = live(conn(), "/issues/#{issue.id}")
    assert progress(view) =~ "No run yet"
    send_progress(view, issue, run, %{bytes: 12, chunks: 2})
    assert progress(view) =~ "No run yet"
  end

  test "event status is not authority even for the current running run", %{issue: issue, run: run} do
    {:ok, view, _} = live(conn(), "/issues/#{issue.id}")
    send_status(view, issue, run, "completed")
    assert progress(view) =~ "Running"
    refute progress(view) =~ "Completed"
  end

  test "persisted terminal states defeat late progress and claimed running status", %{
    issue: issue,
    run: run
  } do
    for {status, label} <- [
          {"completed", "Completed"},
          {"failed", "Failed"},
          {"cancelled", "Cancelled"}
        ] do
      Repo.update!(Ecto.Changeset.change(run, status: "running"))
      {:ok, view, _} = live(conn(), "/issues/#{issue.id}")

      Repo.update!(
        Ecto.Changeset.change(run,
          status: status,
          completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
        )
      )

      send_progress(view, issue, run, %{bytes: 12, chunks: 2})
      assert progress(view) =~ label
      refute progress(view) =~ "Output activity"
      send_status(view, issue, run, "running")
      assert progress(view) =~ label
      refute progress(view) =~ "Running"
    end
  end

  test "new run replaces old counters and ignores old terminal events", %{
    issue: issue,
    agent: agent,
    run: run
  } do
    {:ok, view, _} = live(conn(), "/issues/#{issue.id}")
    send_progress(view, issue, run, %{bytes: 12, chunks: 2})
    newer = insert_run(issue, agent, DateTime.add(run.inserted_at, 2))
    send_status(view, issue, newer, "running")
    assert progress(view) =~ "Waiting for activity"
    refute progress(view) =~ "12 bytes"
    send_status(view, issue, run, "completed")
    send_progress(view, issue, run, %{bytes: 99, chunks: 9})
    refute progress(view) =~ "99 bytes"
    assert progress(view) =~ "Running"
  end

  test "timer reconciles missed terminal events and marks quiet runs stale without failure", %{
    issue: issue,
    run: run
  } do
    {:ok, view, _} = live(conn(), "/issues/#{issue.id}")
    old = DateTime.add(DateTime.utc_now(), -120) |> DateTime.truncate(:second)
    Repo.update!(Ecto.Changeset.change(run, started_at: old, last_heartbeat_at: old))
    send(view.pid, :refresh_run_progress)
    assert progress(view) =~ "Activity unavailable"
    assert progress(view) =~ "Run may still be running"
    Repo.update!(Ecto.Changeset.change(run, status: "failed"))
    send(view.pid, :refresh_run_progress)
    assert progress(view) =~ "Failed"
  end

  test "remount reconstructs running and missed terminal state from persistence", %{
    issue: issue,
    run: run
  } do
    {:ok, first, _} = live(conn(), "/issues/#{issue.id}")
    send_progress(first, issue, run, %{bytes: 12, chunks: 2})
    {:ok, reopened, _} = live(conn(), "/issues/#{issue.id}")
    assert progress(reopened) =~ "Running"
    assert progress(reopened) =~ "Waiting for activity"

    for {status, label} <- [{"completed", "Completed"}, {"failed", "Failed"}] do
      Repo.update!(Ecto.Changeset.change(run, status: status))
      {:ok, reconnected, _} = live(conn(), "/issues/#{issue.id}")
      assert progress(reconnected) =~ label
      refute progress(reconnected) =~ "Running"
    end
  end

  test "membership revocation prevents further progress", %{issue: issue, run: run} do
    {:ok, view, _} = live(conn(), "/issues/#{issue.id}")
    user_id = Plug.Conn.get_session(conn(), :user_id)
    Companies.get_membership(user_id, issue.company_id) |> Companies.delete_membership()
    send_progress(view, issue, run, %{bytes: 12, chunks: 2})
    assert_redirect(view, "/")
  end

  defp insert_run(issue, agent, inserted_at \\ DateTime.utc_now() |> DateTime.truncate(:second)) do
    Repo.insert!(%Run{
      issue_id: issue.id,
      company_id: issue.company_id,
      agent_id: agent.id,
      status: "running",
      adapter: "process",
      inserted_at: inserted_at,
      started_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
  end

  defp progress(view),
    do:
      view
      |> element("#issue-run-progress")
      |> render()
      |> Floki.parse_document!()
      |> Floki.text()

  defp authoritative_progress(issue),
    do: RunProgress.load(Plug.Conn.get_session(conn(), :user_id), issue.company_id, issue.id)

  # Rejected telemetry cannot change status, detail or counters; wall time still advances.
  defp progress_without_elapsed(view),
    do: view |> progress() |> String.replace(~r/Elapsed \d+s/, "Elapsed")

  defp send_progress(view, issue, run, changes) do
    payload =
      Map.merge(
        %{
          company_id: issue.company_id,
          issue_id: issue.id,
          run_id: run.id,
          bytes: 12,
          chunks: 2,
          timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
        },
        changes
      )

    send(view.pid, %Phoenix.Socket.Broadcast{
      topic: "company:#{issue.company_id}:runs",
      event: "run_progress",
      payload: payload
    })
  end

  defp send_status(view, issue, run, status) do
    send(view.pid, %Phoenix.Socket.Broadcast{
      topic: "company:#{issue.company_id}:runs",
      event: "run_status",
      payload: %{
        company_id: issue.company_id,
        issue_id: issue.id,
        resource_id: run.id,
        status: status
      }
    })
  end
end
