defmodule CymphoWeb.AgentLive.PartsTest do
  use ExUnit.Case, async: true

  alias CymphoWeb.AgentLive.Parts

  describe "status/2" do
    # The heartbeat skips a sleeping agent (agent_heartbeat.ex), so "Idle" would say it takes work.
    test "a sleeping agent reads Sleeping, in the idle shape" do
      assert Parts.status(%{status: :sleeping}, false) == {:idle, "Sleeping"}
    end

    test "a running run still reads Working for a sleeping agent" do
      assert Parts.status(%{status: :sleeping}, true) == {:working, "Working"}
    end

    test "an idle agent still reads Idle" do
      assert Parts.status(%{status: :idle}, false) == {:idle, "Idle"}
    end
  end
end
