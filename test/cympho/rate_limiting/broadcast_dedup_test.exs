defmodule Cympho.RateLimiting.BroadcastDedupTest do
  use ExUnit.Case, async: false

  alias Cympho.RateLimiting.BroadcastDedup

  setup do
    BroadcastDedup.reset()
    :ok
  end

  describe "should_broadcast?/3" do
    test "allows first broadcast" do
      assert BroadcastDedup.should_broadcast?("topic", "event", %{foo: "bar"})
    end

    test "blocks identical broadcast within 500ms" do
      BroadcastDedup.should_broadcast?("topic", "event", %{foo: "bar"})
      refute BroadcastDedup.should_broadcast?("topic", "event", %{foo: "bar"})
    end

    test "allows different payloads to same topic" do
      BroadcastDedup.should_broadcast?("topic", "event", %{foo: "bar"})
      assert BroadcastDedup.should_broadcast?("topic", "event", %{foo: "baz"})
    end

    test "allows same payload to different topics" do
      BroadcastDedup.should_broadcast?("topic1", "event", %{foo: "bar"})
      assert BroadcastDedup.should_broadcast?("topic2", "event", %{foo: "bar"})
    end
  end

  describe "should_broadcast_pubsub?/2" do
    test "allows first pubsub broadcast" do
      assert BroadcastDedup.should_broadcast_pubsub?("topic", {:event, %{data: 1}})
    end

    test "blocks duplicate pubsub broadcasts" do
      BroadcastDedup.should_broadcast_pubsub?("topic", {:event, %{data: 1}})
      refute BroadcastDedup.should_broadcast_pubsub?("topic", {:event, %{data: 1}})
    end
  end
end
