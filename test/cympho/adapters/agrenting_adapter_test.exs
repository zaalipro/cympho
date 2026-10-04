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

  defp client_mocks(
         test_pid,
         status,
         cancel_result \\ {:ok, %{"id" => "hire-1", "status" => "cancelled"}}
       ) do
    [
      {Client, [],
       [
         create_hiring: fn _config, _did, _attrs -> {:ok, %{"id" => "hire-1"}} end,
         get_hiring: fn _config, _id ->
           if is_tuple(status), do: status, else: {:ok, %{"id" => "hire-1", "status" => status}}
         end,
         cancel_hiring: fn _config, id ->
           send(test_pid, {:cancelled_remotely, id})
           cancel_result
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

  test "a timed-out paid hiring is cancelled before reporting the hiring ID" do
    with_mocks(client_mocks(self(), "running")) do
      session_id =
        AgrentingAdapter.run(@issue, "agent-1", self(), config: %{@config | "timeout" => 1})

      assert_receive {:turn_ended_with_error, ^session_id,
                      {:agrenting_timeout, "hire-1", "running"}},
                     5_000

      assert_receive {:cancelled_remotely, "hire-1"}, 5_000
      assert eventually(fn -> not AdapterSessions.registered?(session_id) end)
    end
  end

  test "a polling error after creation attempts cancellation and retains the hiring ID" do
    with_mocks(client_mocks(self(), {:error, :provider_unavailable})) do
      session_id = AgrentingAdapter.run(@issue, "agent-1", self(), config: @config)

      assert_receive {:turn_ended_with_error, ^session_id,
                      {:agrenting_poll_failed, "hire-1", :provider_unavailable}},
                     5_000

      assert_receive {:cancelled_remotely, "hire-1"}, 5_000
    end
  end

  test "malformed successful polling payloads cancel the paid hiring and emit one terminal error" do
    for payload <- ["not-json", [], nil] do
      with_mocks(client_mocks(self(), {:ok, payload})) do
        session_id = AgrentingAdapter.run(@issue, "agent-1", self(), config: @config)

        assert_receive {:turn_ended_with_error, ^session_id,
                        {:agrenting_poll_failed, "hire-1", :invalid_hiring_response}},
                       5_000

        assert_receive {:cancelled_remotely, "hire-1"}, 5_000
        refute_receive {:turn_completed, ^session_id, _}, 100
        refute_receive {:turn_ended_with_error, ^session_id, _}, 100
      end
    end
  end

  test "a terminal failed hiring is not cancelled" do
    with_mocks(client_mocks(self(), "failed")) do
      session_id = AgrentingAdapter.run(@issue, "agent-1", self(), config: @config)

      assert_receive {:turn_ended_with_error, ^session_id,
                      {:agrenting_hiring_terminal, "failed", _}},
                     5_000

      refute_receive {:cancelled_remotely, _}, 100
    end
  end

  test "cancellation failure retains the hiring ID and remote uncertainty" do
    with_mocks(client_mocks(self(), {:error, :provider_unavailable}, {:error, :cancel_denied})) do
      session_id = AgrentingAdapter.run(@issue, "agent-1", self(), config: @config)

      assert_receive {:turn_ended_with_error, ^session_id,
                      {:agrenting_cancel_failed, "hire-1",
                       {:agrenting_poll_failed, "hire-1", :provider_unavailable}, :cancel_denied}},
                     5_000

      assert_receive {:cancelled_remotely, "hire-1"}, 5_000
    end
  end

  test "persists omission diagnostics and honest no-omission state through PromptTelemetry" do
    test_pid = self()

    with_mocks([
      {Client, [],
       [
         create_hiring: fn _config, _did, _attrs ->
           send(test_pid, :client_created)
           {:ok, %{"id" => "hire-1"}}
         end,
         get_hiring: fn _config, _id -> {:ok, %{"id" => "hire-1", "status" => "completed"}} end,
         cancel_hiring: fn _config, _id -> {:ok, %{}} end,
         config_value: fn config, key -> Map.get(config, key) end
       ]},
      {Cympho.HeartbeatEngine, [:passthrough],
       [
         merge_run_metadata: fn run_id, metadata ->
           send(test_pid, {:run_metadata_merged, run_id, metadata})
           {:ok, %{}}
         end
       ]}
    ]) do
      # Case 1: Honest no-omission run
      session_id =
        AgrentingAdapter.run(@issue, "agent-1", self(),
          config: @config,
          run_id: "run-agrenting-diag-1"
        )

      assert_receive {:turn_completed, ^session_id, _}, 5_000

      assert_receive {:run_metadata_merged, "run-agrenting-diag-1", metadata}, 2_000
      prompt_context = metadata["prompt_context"]
      assert prompt_context["adapter"] == "agrenting"
      assert prompt_context["omissions"]["omitted"] == false
      assert prompt_context["omissions"]["categories"] == []
      assert prompt_context["omissions"]["counts"] == %{}

      # Case 2: Omission diagnostics without raw content
      omissions_meta = %{
        "omitted" => true,
        "categories" => ["history_comments", "attachments"],
        "counts" => %{"history_comments" => 3, "attachments" => 1},
        "total_omitted_sections" => 2
      }

      prompt_with_omission = """
      ## Current task - do this now
      Task description
      ## Context omissions
      The following optional context was omitted to satisfy the prompt input budget:
      - history_comments: 3 item(s) omitted
      - attachments: 1 item(s) omitted
      """

      session_id2 =
        AgrentingAdapter.run(@issue, "agent-1", self(),
          config: @config,
          run_id: "run-agrenting-diag-2",
          budgeted_prompt: prompt_with_omission,
          omissions: omissions_meta
        )

      assert_receive {:turn_completed, ^session_id2, _}, 5_000

      assert_receive {:run_metadata_merged, "run-agrenting-diag-2", metadata2}, 2_000
      prompt_context2 = metadata2["prompt_context"]
      assert prompt_context2["adapter"] == "agrenting"
      assert prompt_context2["omissions"]["omitted"] == true
      assert prompt_context2["omissions"]["categories"] == ["history_comments", "attachments"]

      assert prompt_context2["omissions"]["counts"] == %{
               "history_comments" => 3,
               "attachments" => 1
             }

      refute inspect(metadata2) =~ "secret_sensitive_omitted_text"
    end
  end

  test "protected prompt input budget overflow prevents hiring creation on Agrenting" do
    test_pid = self()

    with_mocks([
      {Client, [],
       [
         create_hiring: fn _config, _did, _attrs ->
           send(test_pid, :client_should_not_be_called)
           {:ok, %{"id" => "hire-1"}}
         end,
         get_hiring: fn _config, _id -> {:ok, %{"id" => "hire-1", "status" => "completed"}} end,
         cancel_hiring: fn _config, _id -> {:ok, %{}} end,
         config_value: fn config, key -> Map.get(config, key) end
       ]}
    ]) do
      session_id =
        AgrentingAdapter.run(@issue, "agent-1", self(),
          config: Map.put(@config, "input_budget_bytes", 100)
        )

      assert_receive {:turn_ended_with_error, ^session_id,
                      {:prompt_input_budget_exceeded, details}},
                     5_000

      assert details.budget_bytes == 100
      refute_received :client_should_not_be_called
      refute_receive {:turn_completed, ^session_id, _}, 100
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
