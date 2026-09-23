defmodule Cympho.RunProgressTest do
  @moduledoc """
  Adapters buffer stdout until the process exits, so an owner watching an issue
  saw nothing between "running" and a finished comment — for up to the full
  wall-clock cap. `Orchestrator.subscribe/1` advertised
  `orchestrator:<issue_id>` for exactly this, but nothing in the codebase ever
  broadcast there; the only test of it broadcast to itself, so it passed
  without a publisher existing.
  """

  use Cympho.DataCase, async: false

  alias Cympho.Adapters.ProcessAdapter
  alias Cympho.Adapters.RunDeadline
  alias Cympho.Companies
  alias Cympho.Issues
  alias CymphoWeb.Events

  @issue %{
    id: "issue-progress-1",
    title: "Streaming issue",
    description: "Produces output over time",
    status: :todo,
    priority: :medium
  }

  describe "RunDeadline.observe/4" do
    test "reports byte and chunk counts to the run's owner" do
      deadline = RunDeadline.new(5_000)
      session_id = make_ref()

      deadline = RunDeadline.observe(deadline, "hello", session_id, self())

      assert_received {:turn_progress, ^session_id, %{bytes: 5, chunks: 1}}
      assert deadline.bytes == 5
      assert deadline.chunks == 1
    end

    test "throttles so a chatty CLI cannot flood the owner" do
      original = Application.get_env(:cympho, :adapter_progress_interval_ms)
      Application.put_env(:cympho, :adapter_progress_interval_ms, 60_000)
      on_exit(fn -> restore(:adapter_progress_interval_ms, original) end)

      session_id = make_ref()

      deadline =
        Enum.reduce(1..25, RunDeadline.new(5_000), fn _n, acc ->
          RunDeadline.observe(acc, "chunk", session_id, self())
        end)

      # Counting never stops, only reporting does.
      assert deadline.bytes == 125
      assert deadline.chunks == 25

      assert_received {:turn_progress, ^session_id, _}
      refute_received {:turn_progress, ^session_id, _}
    end

    test "still advances the stall deadline when reporting is throttled" do
      original = Application.get_env(:cympho, :adapter_progress_interval_ms)
      Application.put_env(:cympho, :adapter_progress_interval_ms, 60_000)
      on_exit(fn -> restore(:adapter_progress_interval_ms, original) end)

      deadline = RunDeadline.new(5_000)
      first = RunDeadline.observe(deadline, "a", make_ref(), self())
      Process.sleep(5)
      second = RunDeadline.observe(first, "b", make_ref(), self())

      assert second.last_output_at >= first.last_output_at
      assert RunDeadline.expired(second) == nil
    end
  end

  describe "adapter to owner" do
    test "a running subprocess reports progress before it finishes" do
      sleep = System.find_executable("sleep")

      dir =
        Path.join(System.tmp_dir!(), "cympho-progress-#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      File.ln_s!(System.find_executable("python3"), Path.join(dir, "python3"))
      on_exit(fn -> File.rm_rf!(dir) end)

      command = Path.join(dir, "drip-agent")

      File.write!(command, """
      #!/bin/sh
      printf 'first\\n'
      #{sleep} 0.3
      printf 'second\\n'
      """)

      File.chmod!(command, 0o755)

      original = Application.get_env(:cympho, :adapter_progress_interval_ms)
      Application.put_env(:cympho, :adapter_progress_interval_ms, 1)
      on_exit(fn -> restore(:adapter_progress_interval_ms, original) end)

      original_path = System.get_env("PATH") || ""
      System.put_env("PATH", dir)
      on_exit(fn -> System.put_env("PATH", original_path) end)

      session_id =
        ProcessAdapter.run(@issue, "agent-1", self(),
          config: %{"command" => "drip-agent", "timeout" => 10_000, "prompt_stdin" => false}
        )

      assert_receive {:session_started, ^session_id}, 5_000

      # The point: this arrives while the subprocess is still working, not after.
      assert_receive {:turn_progress, ^session_id, %{bytes: bytes, chunks: chunks}}, 5_000
      assert bytes > 0
      assert chunks > 0

      assert_receive {:turn_completed, ^session_id, _result}, 10_000
    end
  end

  describe "broadcast_run_progress/3" do
    setup do
      unique = System.unique_integer([:positive])

      {:ok, company} =
        Companies.create_company(%{
          name: "Progress Co #{unique}",
          slug: "progress-co-#{unique}",
          issue_prefix: "PC"
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Progress issue",
          description: "x",
          status: :in_progress,
          company_id: company.id
        })

      %{company: company, issue: issue}
    end

    test "reaches the topic Orchestrator.subscribe/1 has always advertised", %{issue: issue} do
      :ok = Cympho.Orchestrator.subscribe(issue.id)
      run_id = Ecto.UUID.generate()

      Events.broadcast_run_progress(issue, run_id, %{bytes: 2048, chunks: 7})

      assert_receive {:run_progress, payload}, 2_000
      assert payload.issue_id == issue.id
      assert payload.run_id == run_id
      assert payload.bytes == 2048
      assert payload.chunks == 7
    end

    test "reaches the company runs topic the UI listens on", %{company: company, issue: issue} do
      :ok = Phoenix.PubSub.subscribe(Cympho.PubSub, "company:#{company.id}:runs")

      Events.broadcast_run_progress(issue, Ecto.UUID.generate(), %{bytes: 10, chunks: 1})

      assert_receive %Phoenix.Socket.Broadcast{event: "run_progress", payload: payload}, 2_000
      assert payload.issue_id == issue.id
    end

    test "refuses to broadcast for an unscoped issue" do
      unscoped = %Cympho.Issues.Issue{id: Ecto.UUID.generate(), company_id: nil}

      :ok = Phoenix.PubSub.subscribe(Cympho.PubSub, "company::runs")
      assert :ok = Events.broadcast_run_progress(unscoped, nil, %{bytes: 1, chunks: 1})
      refute_receive %Phoenix.Socket.Broadcast{event: "run_progress"}, 200
    end
  end

  defp restore(key, nil), do: Application.delete_env(:cympho, key)
  defp restore(key, value), do: Application.put_env(:cympho, key, value)
end
