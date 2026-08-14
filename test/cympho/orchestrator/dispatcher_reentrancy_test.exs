defmodule Cympho.Orchestrator.DispatcherReentrancyTest do
  @moduledoc """
  A budget hard-stop is recorded at the end of an agent turn, *inside* the
  orchestrator process, and reaches `Companies.stop_company_runtime/2` →
  `Dispatcher.stop_company/2`. The Dispatcher then walks the company's
  in-progress issues and stops each orchestrator synchronously — including the
  one blocked waiting on this very call.

  Before the fix that mutual wait froze the global, all-tenant Dispatcher for
  ~15 seconds: `get_session_state/1` burned its 5s timeout, `GenServer.stop/2`
  waited `:infinity`, and the caller's own 15s timeout was what finally broke
  it. The enforcement steps after the exception — cancelling company wakes and
  marking the incident complete — were skipped.

  These tests use a stand-in registered under the orchestrator's registry key so
  the Dispatcher's re-entrancy handling can be exercised directly, without
  standing up a full agent turn.
  """

  use Cympho.DataCase, async: false

  alias Cympho.Companies
  alias Cympho.Issues
  alias Cympho.Orchestrator.Dispatcher

  @registry Cympho.OrchestratorRegistry

  setup do
    unless Process.whereis(@registry) do
      start_supervised!({Registry, keys: :unique, name: @registry})
    end

    unless Process.whereis(Dispatcher) do
      {:ok, _pid} = Dispatcher.start_link([])
    end

    unique = System.unique_integer([:positive])

    {:ok, company} =
      Companies.create_company(%{
        name: "Reentrancy Co #{unique}",
        slug: "reentrancy-co-#{unique}",
        issue_prefix: "RC"
      })

    {:ok, issue} =
      Issues.create_issue(%{
        title: "Re-entrant stop",
        description: "Runs while the budget crosses",
        status: :in_progress,
        company_id: company.id
      })

    %{company: company, issue: issue}
  end

  # Registers under the orchestrator's registry key, then calls stop_company
  # from inside itself — the same shape as an orchestrator enforcing a hard stop
  # at the end of a turn.
  defp start_fake_orchestrator(issue_id, company_id, test_pid) do
    spawn(fn ->
      {:ok, _} = Registry.register(@registry, issue_id, nil)
      send(test_pid, {:registered, self()})

      started = System.monotonic_time(:millisecond)
      result = Dispatcher.stop_company(company_id, :budget_hard_stop)
      elapsed = System.monotonic_time(:millisecond) - started

      send(test_pid, {:stop_returned, result, elapsed})

      # The orchestrator's own shutdown path: it processes the async stop as
      # soon as its call returns.
      receive do
        {:stop_orchestrator, reason} -> send(test_pid, {:stopped, reason})
      after
        5_000 -> send(test_pid, :never_signalled)
      end
    end)
  end

  test "a stop requested by an orchestrator does not block on that orchestrator", %{
    company: company,
    issue: issue
  } do
    test_pid = self()
    fake = start_fake_orchestrator(issue.id, company.id, test_pid)

    assert_receive {:registered, ^fake}, 2_000

    # The whole point: this returns promptly instead of grinding through
    # get_session_state's 5s timeout and GenServer.stop's :infinity wait.
    assert_receive {:stop_returned, {:ok, result}, elapsed}, 10_000

    assert elapsed < 3_000,
           "stop_company blocked for #{elapsed}ms — the Dispatcher waited on its own caller"

    assert issue.id in result.issue_ids
    assert result.orchestrators_stopped >= 1
  end

  test "the requesting orchestrator is still told to stop", %{company: company, issue: issue} do
    test_pid = self()
    fake = start_fake_orchestrator(issue.id, company.id, test_pid)

    assert_receive {:registered, ^fake}, 2_000
    assert_receive {:stop_returned, {:ok, _result}, _elapsed}, 10_000

    # Skipping the synchronous stop must not mean skipping the stop.
    assert_receive {:stopped, {:runtime_stop, "budget_hard_stop"}}, 5_000
  end

  test "the Dispatcher stays responsive to other tenants throughout", %{
    company: company,
    issue: issue
  } do
    test_pid = self()
    fake = start_fake_orchestrator(issue.id, company.id, test_pid)

    assert_receive {:registered, ^fake}, 2_000
    assert_receive {:stop_returned, {:ok, _result}, _elapsed}, 10_000

    # An unrelated caller must not have been starved out by the re-entrant stop.
    assert is_list(Dispatcher.running_issue_ids())
  end
end
