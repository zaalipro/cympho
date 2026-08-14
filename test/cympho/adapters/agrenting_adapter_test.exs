defmodule Cympho.Adapters.AgrentingAdapterTest do
  @moduledoc """
  An Agrenting hiring is a *paid* remote job that polls for up to 30 minutes.

  The worker was never registered with `Cympho.AdapterSessions`, so operator
  stop, company pause, and budget hard-stop had no way to reach it, and the poll
  loop slept between attempts so it could not have heard them anyway. A
  cancelled run therefore kept billing until the hiring finished on its own.
  """

  use ExUnit.Case, async: false

  import Mock

  alias Cympho.Adapters.AgrentingAdapter
  alias Cympho.Agrenting.Client
  alias Cympho.AdapterSessions

  @issue %{
    id: "issue-agrenting-1",
    title: "Remote delivery",
    description: "Hire a remote agent.",
    status: :todo,
    priority: :medium,
    project_id: nil
  }

  @config %{
    "agent_did" => "did:agrenting:example",
    "capability" => "code",
    "max_price" => 100,
    "api_key" => "ap_test",
    "poll_interval_ms" => 50,
    "timeout" => 60_000
  }

  defp client_mocks(test_pid, status) do
    [
      {Client, [],
       [
         create_hiring: fn _config, _did, _attrs -> {:ok, %{"id" => "hire-1"}} end,
         get_hiring: fn _config, _id -> {:ok, %{"id" => "hire-1", "status" => status}} end,
         cancel_hiring: fn _config, id ->
           send(test_pid, {:cancelled_remotely, id})
           {:ok, %{"id" => id, "status" => "cancelled"}}
         end,
         config_value: fn config, key -> Map.get(config, key) end
       ]}
    ]
  end

  test "an operator stop cancels the run and the remote hiring" do
    test_pid = self()

    with_mocks(client_mocks(test_pid, "running")) do
      session_id = AgrentingAdapter.run(@issue, "agent-1", self(), config: @config)

      assert_receive {:session_started, ^session_id}, 2_000

      # Registration is what makes every operator control path reach this run.
      assert eventually(fn -> AdapterSessions.registered?(session_id) end)

      assert :ok = AdapterSessions.cancel(session_id, :operator_stop)

      assert_receive {:turn_ended_with_error, ^session_id, {:cancelled, :operator_stop}}, 5_000
      assert_receive {:cancelled_remotely, "hire-1"}, 5_000
    end
  end

  test "a dead orchestrator cancels the remote hiring instead of letting it bill" do
    test_pid = self()

    with_mocks(client_mocks(test_pid, "running")) do
      owner = spawn(fn -> Process.sleep(:infinity) end)

      session_id = AgrentingAdapter.run(@issue, "agent-1", owner, config: @config)

      assert eventually(fn -> AdapterSessions.registered?(session_id) end)

      Process.exit(owner, :kill)

      assert_receive {:cancelled_remotely, "hire-1"}, 5_000
    end
  end

  test "a hiring that completes normally is not cancelled remotely" do
    test_pid = self()

    with_mocks(client_mocks(test_pid, "completed")) do
      session_id = AgrentingAdapter.run(@issue, "agent-1", self(), config: @config)

      assert_receive {:session_started, ^session_id}, 2_000
      assert_receive {:turn_completed, ^session_id, _result}, 5_000
      refute_received {:cancelled_remotely, _}
    end
  end

  test "the session is unregistered once the run ends" do
    test_pid = self()

    with_mocks(client_mocks(test_pid, "completed")) do
      session_id = AgrentingAdapter.run(@issue, "agent-1", self(), config: @config)

      assert_receive {:turn_completed, ^session_id, _result}, 5_000
      assert eventually(fn -> not AdapterSessions.registered?(session_id) end)
    end
  end

  defp eventually(fun, attempts \\ 60) do
    cond do
      fun.() -> true
      attempts <= 1 -> false
      true -> Process.sleep(25) && eventually(fun, attempts - 1)
    end
  end
end
