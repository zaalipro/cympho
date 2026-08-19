defmodule Cympho.Decisions.ExecutorTest do
  use Cympho.DataCase, async: false

  alias Cympho.{Agents, Companies, Decisions, Issues, Projects, Repo}
  alias Cympho.Decisions.Decision
  alias Cympho.Decisions.Executor

  setup do
    {:ok, company} =
      Companies.create_company(%{
        name: "Exec Co #{System.unique_integer([:positive])}",
        slug: "exec-#{System.unique_integer([:positive])}"
      })

    {:ok, project} =
      Projects.create_project(%{
        name: "P",
        prefix: "EXC",
        company_id: company.id
      })

    %{company: company, project: project}
  end

  describe "execute/1" do
    test "cancel_project archives the project + cancels open issues", %{
      company: company,
      project: project
    } do
      {:ok, i1} =
        Issues.create_issue(%{
          title: "Task 1",
          status: :todo,
          priority: :medium,
          company_id: company.id,
          project_id: project.id
        })

      {:ok, i2} =
        Issues.create_issue(%{
          title: "Task 2",
          status: :in_progress,
          priority: :medium,
          company_id: company.id,
          project_id: project.id
        })

      decision = %Decision{
        id: Ecto.UUID.generate(),
        company_id: company.id,
        decision_key: "cancel_project:" <> project.id,
        decision_type: "strategic",
        outcome: "cancelled",
        reasoning: "pivot"
      }

      assert :ok = Executor.execute(decision)

      assert Issues.get_issue!(i1.id).status == :cancelled
      assert Issues.get_issue!(i2.id).status == :cancelled
      assert Repo.get!(Cympho.Projects.Project, project.id).status == :archived

      assert :ok = Executor.execute(decision)
    end

    test "pause_engineer flips governance_status to paused", %{company: company} do
      {:ok, eng} =
        Agents.create_agent(%{
          name: "Bob",
          role: :engineer,
          status: :idle,
          company_id: company.id
        })

      decision = %Decision{
        id: Ecto.UUID.generate(),
        company_id: company.id,
        decision_key: "pause_engineer:" <> eng.id,
        decision_type: "governance",
        outcome: "paused",
        reasoning: "Excessive failures"
      }

      assert :ok = Executor.execute(decision)

      reloaded = Repo.get!(Cympho.Agents.Agent, eng.id)
      assert reloaded.governance_status == "paused"
      assert reloaded.pause_reason =~ "Excessive failures"

      assert :ok = Executor.execute(decision)
    end

    test "cancel_issue terminates a specific issue", %{company: company, project: project} do
      {:ok, issue} =
        Issues.create_issue(%{
          title: "Doomed",
          status: :in_progress,
          priority: :medium,
          company_id: company.id,
          project_id: project.id
        })

      decision = %Decision{
        id: Ecto.UUID.generate(),
        company_id: company.id,
        decision_key: "cancel_issue:" <> issue.id,
        decision_type: "strategic",
        outcome: "cancelled",
        reasoning: "no longer needed"
      }

      assert :ok = Executor.execute(decision)
      assert Issues.get_issue!(issue.id).status == :cancelled

      assert :ok = Executor.execute(decision)
    end

    test "unknown decision_key is a no-op", %{company: company} do
      decision = %Decision{
        id: Ecto.UUID.generate(),
        company_id: company.id,
        decision_key: "make_breakfast",
        decision_type: "strategic"
      }

      assert :ok = Executor.execute(decision)
    end
  end

  describe "durable execution" do
    test "replays a decision created while the executor was down", %{
      company: company,
      project: project
    } do
      {:ok, issue} = create_issue(company, project, "Created during downtime")
      {:ok, decision} = create_cancel_issue_decision(company, issue)

      assert decision.execution_state == "pending"
      assert decision.execution_attempts == 0
      assert decision.execution_available_at
      assert Issues.get_issue!(issue.id).status == :in_progress

      start_supervised!({Executor, idle_poll_ms: 20})

      wait_until(fn ->
        assert Issues.get_issue!(issue.id).status == :cancelled
        assert Decisions.get_decision!(decision.id).execution_state == "completed"
      end)
    end

    test "reclaims an interrupted execution on restart", %{
      company: company,
      project: project
    } do
      {:ok, issue} = create_issue(company, project, "Interrupted execution")
      {:ok, decision} = create_cancel_issue_decision(company, issue)

      decision
      |> Ecto.Changeset.change(%{
        execution_state: "processing",
        execution_locked_at: DateTime.add(DateTime.utc_now(), -301, :second),
        execution_locked_by: Ecto.UUID.generate()
      })
      |> Repo.update!()

      start_supervised!({Executor, idle_poll_ms: 20})

      wait_until(fn ->
        assert Issues.get_issue!(issue.id).status == :cancelled
        assert Decisions.get_decision!(decision.id).execution_state == "completed"
      end)
    end

    test "does not reclaim a fresh claim left by another executor", %{company: company} do
      {:ok, decision} =
        Decisions.create_decision(%{
          decision_type: "strategic",
          decision_key: "fresh-claim-test:#{Ecto.UUID.generate()}",
          outcome: "approved",
          actor_type: "system",
          actor_id: Ecto.UUID.generate(),
          company_id: company.id
        })

      claim_token = Ecto.UUID.generate()

      decision
      |> Ecto.Changeset.change(%{
        execution_state: "processing",
        execution_locked_at: DateTime.utc_now(),
        execution_locked_by: claim_token
      })
      |> Repo.update!()

      {:ok, attempts} = Elixir.Agent.start_link(fn -> 0 end)

      start_supervised!(
        {Executor,
         execute: fn _decision -> Elixir.Agent.update(attempts, &(&1 + 1)) end,
         idle_poll_ms: 20,
         lock_timeout_ms: 300_000}
      )

      Process.sleep(100)

      reloaded = Decisions.get_decision!(decision.id)
      assert reloaded.execution_state == "processing"
      assert reloaded.execution_locked_by == claim_token
      assert Elixir.Agent.get(attempts, & &1) == 0
    end

    test "persists a crashed task failure and retries it with backoff", %{company: company} do
      {:ok, decision} =
        Decisions.create_decision(%{
          decision_type: "strategic",
          decision_key: "retry-test:#{Ecto.UUID.generate()}",
          outcome: "approved",
          actor_type: "system",
          actor_id: Ecto.UUID.generate(),
          company_id: company.id
        })

      {:ok, attempts} = Elixir.Agent.start_link(fn -> 0 end)

      execute = fn _decision ->
        attempt = Elixir.Agent.get_and_update(attempts, fn count -> {count + 1, count + 1} end)

        if attempt == 1 do
          raise "temporary execution failure"
        else
          :ok
        end
      end

      ExUnit.CaptureLog.capture_log(fn ->
        start_supervised!(
          {Executor, execute: execute, base_backoff_ms: 10, max_backoff_ms: 10, idle_poll_ms: 20}
        )

        wait_until(fn ->
          reloaded = Decisions.get_decision!(decision.id)
          assert reloaded.execution_state == "completed"
          assert reloaded.execution_attempts == 2
          assert Elixir.Agent.get(attempts, & &1) == 2
        end)
      end)
    end

    test "stops retrying after the configured attempt bound", %{company: company} do
      {:ok, decision} =
        Decisions.create_decision(%{
          decision_type: "strategic",
          decision_key: "retry-bound-test:#{Ecto.UUID.generate()}",
          outcome: "approved",
          actor_type: "system",
          actor_id: Ecto.UUID.generate(),
          company_id: company.id
        })

      {:ok, attempts} = Elixir.Agent.start_link(fn -> 0 end)

      execute = fn _decision ->
        Elixir.Agent.update(attempts, &(&1 + 1))
        {:error, :temporary_failure}
      end

      ExUnit.CaptureLog.capture_log(fn ->
        start_supervised!(
          {Executor,
           execute: execute,
           max_attempts: 2,
           base_backoff_ms: 5,
           max_backoff_ms: 5,
           idle_poll_ms: 20}
        )

        wait_until(fn ->
          reloaded = Decisions.get_decision!(decision.id)
          assert reloaded.execution_state == "failed"
          assert reloaded.execution_attempts == 2
          assert Elixir.Agent.get(attempts, & &1) == 2
        end)
      end)
    end
  end

  defp create_issue(company, project, title) do
    Issues.create_issue(%{
      title: title,
      status: :in_progress,
      priority: :medium,
      company_id: company.id,
      project_id: project.id
    })
  end

  defp create_cancel_issue_decision(company, issue) do
    Decisions.create_decision(%{
      decision_type: "strategic",
      decision_key: "cancel_issue:" <> issue.id,
      outcome: "cancelled",
      reasoning: "no longer needed",
      actor_type: "system",
      actor_id: Ecto.UUID.generate(),
      resource_type: "issue",
      resource_id: issue.id,
      company_id: company.id
    })
  end
end
