defmodule CymphoWeb.ReviewReworkProcessTest do
  use CymphoWeb.LiveCase, async: false

  alias Cympho.{
    AdapterSessions,
    AgentPrompt,
    AgentPromptBudget,
    Agents,
    Comments,
    HeartbeatEngine,
    Issues,
    Orchestrator,
    RuntimeAdmission
  }

  @moduletag :capture_log

  test "human review form delivers the newest complete attributed reason to a budgeted managed process",
       %{conn: conn} do
    user_id = Plug.Conn.get_session(conn, :user_id)

    {:ok, engineer} =
      Agents.create_agent(
        scoped_attrs(%{
          name: "Synthetic rework engineer",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "/usr/bin/false", "repo_capable" => true}
        })
      )

    {:ok, issue} =
      Issues.create_issue(
        scoped_attrs(%{
          title: "Budgeted human rework",
          description: "Apply the latest human review reason to this synthetic document.",
          status: :in_review,
          assigned_role: "cto",
          last_reviewer_id: engineer.id
        })
      )

    {:ok, _} =
      Comments.create_comment(%{
        issue_id: issue.id,
        author_type: "user",
        author_id: user_id,
        body: "[review] Verdict: changes requested.\nReason: OLDER_REVIEW_SENTINEL"
      })

    reason =
      "Fix the UTF-8 boundary: café.\n" <>
        String.duplicate("Preserve the complete multiline human reason. ", 65) <>
        "\nLATEST_REVIEW_END: verify the corrected document."

    {:ok, review, _} = live(conn, "/reviews")
    render_hook(review, "request_changes", %{"id" => issue.id})

    review
    |> element("#review-changes-form")
    |> render_submit(%{"review" => %{"reason" => reason}})

    rework = Issues.get_issue!(issue.id)
    assert rework.status == :todo
    assert rework.last_human_reviewer_id == user_id

    assert Enum.any?(Comments.list_comments(issue.id), fn comment ->
             comment.author_type == "user" and comment.author_id == user_id and
               comment.body == "[review] Verdict: changes requested.\nReason: " <> reason
           end)

    {:ok, conversation, html} = live(conn, "/issues/#{issue.id}")
    assert html =~ "LATEST_REVIEW_END"
    assert html =~ "Live User"
    GenServer.stop(conversation.pid)
    GenServer.stop(review.pid)

    # Later routine conversation must not supersede or bury the required reason.
    for index <- 1..60 do
      {:ok, _} =
        Comments.create_comment(%{
          issue_id: issue.id,
          author_type: "user",
          author_id: user_id,
          body:
            "OPTIONAL_THREAD_SENTINEL #{index}: Thanks for the review feedback. " <>
              String.duplicate("Routine scheduling note. ", 25)
        })
    end

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, checked_out} =
      Issues.update_issue(Issues.get_issue!(issue.id), %{
        status: :in_progress,
        assignee_id: engineer.id,
        checked_out_at: now,
        started_at: now
      })

    protected =
      checked_out
      |> AgentPrompt.build_sections(engineer.id)
      |> Enum.filter(&(&1.type == :protected))
      |> AgentPromptBudget.assemble_prompt(nil)

    budget = byte_size(protected) + 1_024
    root = Path.join(System.tmp_dir!(), "cympho-review-rework-#{Ecto.UUID.generate()}")
    File.mkdir!(root)
    script = Path.join(root, "capture.sh")
    capture = Path.join(root, "prompt.txt")
    child_pid = Path.join(root, "child.pid")

    on_exit(fn ->
      :ok = Orchestrator.stop(issue.id, :test_cleanup)
      File.rm_rf!(root)
    end)

    File.write!(script, """
    #!/bin/sh
    echo $$ > '#{child_pid}'
    cat > '#{capture}'
    cat <<'EOF'
    ```cympho-actions
    {"actions":[
      {"type":"comment","body":"Synthetic rework received the human reason."},
      {"type":"handoff","role":"product_manager","summary":"Synthetic rework ready for review."}
    ]}
    ```
    EOF
    """)

    File.chmod!(script, 0o700)

    {:ok, pid} =
      Orchestrator.start_and_run(checked_out, engineer.id,
        adapter: :process,
        adapter_config: %{"command" => script, "cwd" => root, "max_run_ms" => 5_000},
        input_budget_bytes: budget
      )

    monitor = Process.monitor(pid)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 8_000
    delivered = File.read!(capture)
    assert byte_size(delivered) <= budget

    assert delivered =~
             "[user #{String.slice(user_id, 0, 8)}] [review] Verdict: changes requested.\nReason: " <>
               reason

    assert delivered =~ "## Context omissions"
    assert delivered =~ "history_comments"
    assert delivered =~ "## Required response contract"
    assert delivered =~ "cympho-actions"
    refute delivered =~ "OPTIONAL_THREAD_SENTINEL"

    assert [run | _] = HeartbeatEngine.list_runs_for_issue(issue.id)
    assert run.status == "completed", run.error_reason || run.log_excerpt || "run failed"
    assert is_nil(Issues.get_issue!(issue.id).checkout_run_id)

    assert Enum.any?(
             Comments.list_comments(issue.id),
             &(&1.body == "Synthetic rework received the human reason.")
           )

    wait_until(fn -> assert {:ok, []} = AdapterSessions.owners_for_issue(issue.id) end)
    assert RuntimeAdmission.snapshot().total_running == 0
    assert RuntimeAdmission.snapshot().local_running == 0
    os_pid = child_pid |> File.read!() |> String.trim()
    {output, status} = System.cmd("/bin/kill", ["-0", os_pid], stderr_to_stdout: true)
    assert status != 0
    assert String.downcase(output) =~ "no such process"
  end
end
