defmodule Cympho.HeartbeatEngine.RunTest do
  use Cympho.DataCase, async: true

  alias Cympho.HeartbeatEngine.Run

  describe "create_changeset/2" do
    test "validates required fields" do
      changeset = Run.create_changeset(%Run{}, %{})

      errors = errors_on(changeset)
      assert :agent_id in Keyword.keys(errors)
      assert :issue_id in Keyword.keys(errors)
      assert :adapter in Keyword.keys(errors)
    end

    test "sets status to pending" do
      changeset =
        Run.create_changeset(%Run{}, %{
          agent_id: Ecto.UUID.generate(),
          issue_id: Ecto.UUID.generate(),
          adapter: "claude_local"
        })

      assert changeset.changes.status == "pending"
    end
  end

  describe "start_changeset/2" do
    test "transitions to running and sets timestamps" do
      run = %Run{status: "pending", id: Ecto.UUID.generate()}
      changeset = Run.start_changeset(run, %{workspace_path: "/tmp/test"})

      assert changeset.changes.status == "running"
      assert changeset.changes.started_at
      assert changeset.changes.workspace_path == "/tmp/test"
    end
  end

  describe "complete_changeset/2" do
    test "transitions to completed with cost data" do
      run = %Run{status: "running", id: Ecto.UUID.generate()}

      changeset =
        Run.complete_changeset(run, %{
          input_tokens: 1000,
          output_tokens: 500,
          cost_usd: Decimal.new("0.05")
        })

      assert changeset.changes.status == "completed"
      assert changeset.changes.completed_at
      assert changeset.changes.input_tokens == 1000
    end
  end

  describe "fail_changeset/2" do
    test "transitions to failed with error reason" do
      run = %Run{status: "running", id: Ecto.UUID.generate()}
      changeset = Run.fail_changeset(run, %{error_reason: "timeout"})

      assert changeset.changes.status == "failed"
      assert changeset.changes.error_reason == "timeout"
      assert changeset.changes.completed_at
    end
  end

  describe "heartbeat_changeset/1" do
    test "updates last_heartbeat_at" do
      run = %Run{status: "running", id: Ecto.UUID.generate()}
      changeset = Run.heartbeat_changeset(run)

      assert changeset.changes.last_heartbeat_at
    end
  end
end
