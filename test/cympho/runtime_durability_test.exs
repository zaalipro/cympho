defmodule Cympho.RuntimeDurabilityTest do
  use Cympho.DataCase, async: false

  alias Cympho.Finances.TokenUsage
  alias Cympho.HeartbeatEngine
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.HeartbeatEngine.WakeupQueue
  alias Cympho.Orchestrator.Dispatcher
  alias Cympho.Workspaces
  alias Cympho.Workspaces.Drivers.Fake
  alias Cympho.Workspaces.EnvironmentLifecycle

  setup do
    unique = System.unique_integer([:positive])

    {:ok, company} =
      Cympho.Companies.create_company(%{
        name: "Runtime durability #{unique}",
        slug: "runtime-durability-#{unique}"
      })

    {:ok, agent} =
      Cympho.Agents.create_agent(%{
        company_id: company.id,
        name: "Runtime durability agent #{unique}",
        role: :engineer,
        status: :idle
      })

    {:ok, project} =
      Cympho.Projects.create_project(%{
        company_id: company.id,
        name: "Runtime durability project #{unique}",
        prefix: "RDTEST"
      })

    {:ok, issue} =
      Cympho.Issues.create_issue(%{
        company_id: company.id,
        project_id: project.id,
        assignee_id: agent.id,
        title: "Runtime durability issue #{unique}"
      })

    %{company: company, agent: agent, project: project, issue: issue, unique: unique}
  end

  describe "terminal usage reconciliation" do
    test "repairs a missing ledger row once and remains idempotent", context do
      run = insert_terminal_run(context, input_tokens: 120, output_tokens: 30, cost_usd: "0.25")

      refute Repo.exists?(from usage in TokenUsage, where: usage.heartbeat_run_id == ^run.id)

      assert {:ok, 1} =
               HeartbeatEngine.reconcile_unrecorded_terminal_usage(context.company.id)

      assert %TokenUsage{input_tokens: 120, output_tokens: 30} =
               Repo.get_by!(TokenUsage, heartbeat_run_id: run.id)

      assert {:ok, 0} =
               HeartbeatEngine.reconcile_unrecorded_terminal_usage(context.company.id)
    end

    test "new run admission reconciles earlier terminal spend first", context do
      old_run = insert_terminal_run(context, input_tokens: 50, cost_usd: "0.10")

      assert {:ok, new_run} =
               HeartbeatEngine.create_run(%{
                 company_id: context.company.id,
                 agent_id: context.agent.id,
                 issue_id: context.issue.id,
                 adapter: "process"
               })

      assert new_run.status == "pending"
      assert Repo.get_by!(TokenUsage, heartbeat_run_id: old_run.id)
    end

    test "new run admission fails closed while durable spend cannot be ledgered", context do
      # Run terminal changesets historically accepted a negative provider token
      # count. The ledger correctly rejects it; admission must not silently skip
      # that durable-but-unreconciled spend and create more work.
      insert_terminal_run(context, input_tokens: -1, cost_usd: "0.10")

      assert {:error, :usage_reconciliation_pending} =
               HeartbeatEngine.create_run(%{
                 company_id: context.company.id,
                 agent_id: context.agent.id,
                 issue_id: context.issue.id,
                 adapter: "process"
               })

      assert HeartbeatEngine.list_runs_for_issue(context.issue.id) |> length() == 1
    end
  end

  describe "atomic wake queue operations" do
    setup do
      original = Application.get_env(:cympho, :wakeup_queue, [])
      Application.put_env(:cympho, :wakeup_queue, max_pending_per_agent: 1)
      on_exit(fn -> Application.put_env(:cympho, :wakeup_queue, original) end)
      :ok
    end

    test "concurrent enqueues cannot exceed the per-agent cap", context do
      {:ok, second_issue} =
        Cympho.Issues.create_issue(%{
          company_id: context.company.id,
          project_id: context.project.id,
          title: "Second durability issue #{context.unique}"
        })

      attrs = [
        %{
          agent_id: context.agent.id,
          issue_id: context.issue.id,
          reason: "issue_commented"
        },
        %{
          agent_id: context.agent.id,
          issue_id: second_issue.id,
          reason: "issue_blockers_resolved"
        }
      ]

      results =
        attrs
        |> Task.async_stream(&WakeupQueue.enqueue/1, max_concurrency: 2, ordered: false)
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &match?({:ok, _wake}, &1)) == 1
      assert Enum.count(results, &(&1 == {:error, :wakeup_queue_full})) == 1
      assert WakeupQueue.pending_count(context.agent.id) == 1
    end

    test "dequeue claims the row before releasing its lock", context do
      assert {:ok, wake} =
               WakeupQueue.enqueue(%{
                 agent_id: context.agent.id,
                 issue_id: context.issue.id,
                 reason: "issue_commented"
               })

      assert {:ok, claimed} = WakeupQueue.dequeue(context.agent.id)
      assert claimed.id == wake.id
      assert claimed.status == "running"
      assert claimed.attempt_count == 1
      assert {:error, :empty} = WakeupQueue.dequeue(context.agent.id)
    end
  end

  describe "remote acquisition durability" do
    test "concurrent workspace acquisition leaves one live provider", context do
      workspace = create_remote_workspace(context)
      :ok = Fake.release("fake-prime-table")

      results =
        1..8
        |> Task.async_stream(
          fn _ -> EnvironmentLifecycle.ensure_acquired(workspace) end,
          max_concurrency: 8
        )
        |> Enum.map(fn {:ok, {:ok, acquired}} -> acquired end)

      assert [provider_ref] = results |> Enum.map(& &1.provider_ref) |> Enum.uniq()
      assert Workspaces.get_execution_workspace!(workspace.id).provider_ref == provider_ref

      live_refs =
        :cympho_env_driver_fake
        |> :ets.tab2list()
        |> Enum.filter(fn {_ref, entry} ->
          entry.company_id == context.company.id and entry.status == :acquired
        end)

      assert [{^provider_ref, _entry}] = live_refs
    end

    test "concurrent logical lease retries acquire and persist once", context do
      {:ok, environment} =
        Workspaces.create_environment(%{
          name: "Runtime durability lease environment",
          status: "active",
          company_id: context.company.id,
          project_id: context.project.id,
          provider: "fake"
        })

      :ok = Fake.release("fake-prime-table")
      before_refs = fake_refs_for_company(context.company.id)

      attrs = %{
        status: "active",
        company_id: context.company.id,
        environment_id: environment.id,
        provider: "fake"
      }

      leases =
        1..8
        |> Task.async_stream(fn _ -> Workspaces.create_lease(attrs) end, max_concurrency: 8)
        |> Enum.map(fn {:ok, {:ok, lease}} -> lease end)

      assert [lease_id] = leases |> Enum.map(& &1.id) |> Enum.uniq()

      assert %Workspaces.EnvironmentLease{id: ^lease_id} =
               Repo.get!(Workspaces.EnvironmentLease, lease_id)

      new_live_refs =
        :cympho_env_driver_fake
        |> :ets.tab2list()
        |> Enum.reject(fn {ref, _entry} -> MapSet.member?(before_refs, ref) end)
        |> Enum.filter(fn {_ref, entry} ->
          entry.company_id == context.company.id and entry.status == :acquired
        end)

      assert [{_provider_ref, _entry}] = new_live_refs
    end

    test "invalid lease scope fails before acquiring a provider", context do
      :ok = Fake.release("fake-prime-table")

      before_refs = fake_refs_for_company(context.company.id)

      assert {:error, %Ecto.Changeset{}} =
               Workspaces.create_lease(%{
                 status: "active",
                 company_id: context.company.id,
                 provider: "fake"
               })

      new_entries =
        :cympho_env_driver_fake
        |> :ets.tab2list()
        |> Enum.reject(fn {ref, _entry} -> MapSet.member?(before_refs, ref) end)
        |> Enum.filter(fn {_ref, entry} -> entry.company_id == context.company.id end)

      assert new_entries == []
    end
  end

  describe "bounded company stop" do
    test "a wedged orchestrator cannot block the global dispatcher", context do
      original = Application.get_env(:cympho, :orchestrator, [])

      Application.put_env(
        :cympho,
        :orchestrator,
        Keyword.put(original, :company_stop_deadline_ms, 100)
      )

      on_exit(fn -> Application.put_env(:cympho, :orchestrator, original) end)

      context.issue
      |> Ecto.Changeset.change(status: :in_progress)
      |> Repo.update!()

      test_pid = self()

      fake =
        spawn(fn ->
          {:ok, _} = Registry.register(Cympho.OrchestratorRegistry, context.issue.id, nil)
          send(test_pid, {:fake_registered, self()})

          receive do
            {:"$gen_call", _from, :get_session_state} ->
              send(test_pid, :company_stop_waiting_on_fake)
              Process.sleep(:infinity)
          end
        end)

      on_exit(fn -> Process.exit(fake, :kill) end)
      assert_receive {:fake_registered, ^fake}

      stop_task =
        Task.async(fn -> Dispatcher.stop_company(context.company.id, :durability_test) end)

      assert_receive :company_stop_waiting_on_fake, 2_000

      started_at = System.monotonic_time(:millisecond)
      assert %Cympho.Orchestrator.Dispatcher.State{} = Dispatcher.state()
      elapsed = System.monotonic_time(:millisecond) - started_at

      assert elapsed < 500

      assert {:ok, result} = Task.await(stop_task, 2_000)
      assert context.issue.id in result.issue_ids

      assert Enum.any?(result.errors, fn error ->
               error.reason =~ "company_stop_deadline_exceeded"
             end)
    end
  end

  defp insert_terminal_run(context, opts) do
    Repo.insert!(%Run{
      company_id: context.company.id,
      agent_id: context.agent.id,
      issue_id: context.issue.id,
      adapter: "process",
      status: "completed",
      input_tokens: Keyword.get(opts, :input_tokens, 0),
      output_tokens: Keyword.get(opts, :output_tokens, 0),
      cost_usd: Decimal.new(Keyword.get(opts, :cost_usd, "0")),
      completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
  end

  defp create_remote_workspace(context) do
    cwd = Path.join("/tmp/cympho", "runtime-durability-#{context.unique}")
    File.mkdir_p!(cwd)
    on_exit(fn -> File.rm_rf(cwd) end)

    {:ok, project_workspace} =
      Workspaces.create_project_workspace(%{
        company_id: context.company.id,
        project_id: context.project.id,
        name: "Runtime durability workspace",
        cwd: cwd
      })

    {:ok, workspace} =
      Workspaces.create_execution_workspace(%{
        company_id: context.company.id,
        project_id: context.project.id,
        project_workspace_id: project_workspace.id,
        source_issue_id: context.issue.id,
        name: "Runtime durability remote workspace",
        status: "open",
        cwd: cwd,
        provider_type: "fake"
      })

    workspace
  end

  defp fake_refs_for_company(company_id) do
    :cympho_env_driver_fake
    |> :ets.tab2list()
    |> Enum.filter(fn {_ref, entry} -> entry.company_id == company_id end)
    |> MapSet.new(fn {ref, _entry} -> ref end)
  end
end
