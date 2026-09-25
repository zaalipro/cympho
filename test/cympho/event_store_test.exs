defmodule Cympho.EventStoreTest do
  use ExUnit.Case, async: false

  setup do
    # purge_old/1 only visits 200 topics per call, so it cannot clear a busy suite's store.
    Cympho.EventStore.purge_topics_with_prefix("")
    :ok
  end

  describe "append/2" do
    test "returns a monotonic event_id" do
      id1 = Cympho.EventStore.append("test_a", %{action: "create"})
      id2 = Cympho.EventStore.append("test_a", %{action: "update"})
      assert is_integer(id1)
      assert id2 > id1
    end
  end

  describe "purge_old/1 index ordering" do
    # A purge tick rewrites each visited topic's id index. It must preserve the
    # newest-first invariant that fetch_since/3 and fetch_latest rely on, even
    # when nothing is old enough to be evicted.
    test "replay still works after a purge that evicts nothing" do
      id1 = Cympho.EventStore.append("test_purge_order", %{n: 1})
      _id2 = Cympho.EventStore.append("test_purge_order", %{n: 2})
      _id3 = Cympho.EventStore.append("test_purge_order", %{n: 3})

      assert 0 = Cympho.EventStore.purge_old(300_000)

      assert {:ok, events} = Cympho.EventStore.fetch_since("test_purge_order", id1)
      assert Enum.map(events, & &1.payload) == [%{n: 2}, %{n: 3}]
    end

    test "fetch_latest returns the newest events after a purge" do
      _id1 = Cympho.EventStore.append("test_purge_latest", %{n: 1})
      _id2 = Cympho.EventStore.append("test_purge_latest", %{n: 2})
      _id3 = Cympho.EventStore.append("test_purge_latest", %{n: 3})

      assert 0 = Cympho.EventStore.purge_old(300_000)

      {:ok, events} = Cympho.EventStore.fetch_since("test_purge_latest", nil, 2)
      assert Enum.map(events, & &1.payload) == [%{n: 2}, %{n: 3}]
    end

    test "events appended after a purge stay replayable" do
      _id1 = Cympho.EventStore.append("test_purge_append", %{n: 1})
      assert 0 = Cympho.EventStore.purge_old(300_000)

      id2 = Cympho.EventStore.append("test_purge_append", %{n: 2})
      _id3 = Cympho.EventStore.append("test_purge_append", %{n: 3})

      assert {:ok, events} = Cympho.EventStore.fetch_since("test_purge_append", id2)
      assert Enum.map(events, & &1.payload) == [%{n: 3}]
    end
  end

  describe "fetch_since/3" do
    test "returns events after the given event_id" do
      id1 = Cympho.EventStore.append("test_b", %{n: 1})
      _id2 = Cympho.EventStore.append("test_b", %{n: 2})
      _id3 = Cympho.EventStore.append("test_b", %{n: 3})
      {:ok, events} = Cympho.EventStore.fetch_since("test_b", id1)
      assert length(events) == 2
      assert Enum.at(events, 0).payload == %{n: 2}
      assert Enum.at(events, 1).payload == %{n: 3}
    end

    test "respects the limit parameter" do
      id0 = Cympho.EventStore.append("test_c", %{n: 0})
      _id1 = Cympho.EventStore.append("test_c", %{n: 1})
      _id2 = Cympho.EventStore.append("test_c", %{n: 2})
      {:ok, events} = Cympho.EventStore.fetch_since("test_c", id0, 1)
      assert length(events) == 1
    end

    test "returns empty list when no events after given id" do
      id = Cympho.EventStore.append("test_d", %{n: 1})
      {:ok, events} = Cympho.EventStore.fetch_since("test_d", id)
      assert events == []
    end

    test "returns empty list for unknown topic" do
      {:ok, events} = Cympho.EventStore.fetch_since("nonexistent_topic", 0)
      assert events == []
    end

    test "with nil last_event_id returns latest events" do
      Cympho.EventStore.append("test_e", %{n: 1})
      Cympho.EventStore.append("test_e", %{n: 2})
      {:ok, events} = Cympho.EventStore.fetch_since("test_e", nil)
      assert length(events) == 2
    end
  end

  describe "count/1" do
    test "returns correct count for a topic" do
      Cympho.EventStore.append("count_a", %{a: 1})
      Cympho.EventStore.append("count_a", %{a: 2})
      Cympho.EventStore.append("count_b", %{b: 1})
      assert Cympho.EventStore.count("count_a") == 2
      assert Cympho.EventStore.count("count_b") == 1
    end
  end

  describe "event map structure" do
    test "each event has event_id, topic, payload, timestamp" do
      Cympho.EventStore.append("struct_topic", %{hello: "world"})
      {:ok, [event]} = Cympho.EventStore.fetch_since("struct_topic", nil)
      assert Map.has_key?(event, :event_id)
      assert event.topic == "struct_topic"
      assert event.payload == %{hello: "world"}
      assert is_integer(event.timestamp)
    end
  end

  describe "dedup_broadcast/3 populates EventStore" do
    test "appends on a real broadcast without a manual append" do
      topic = "company:#{Ecto.UUID.generate()}:issues"
      payload = %{action: "create"}

      Cympho.RateLimiting.BroadcastDedup.reset()
      assert :ok = Cympho.RateLimiting.dedup_broadcast(topic, "issue_update", payload)

      {:ok, events} = Cympho.EventStore.fetch_since(topic, nil)
      assert length(events) == 1
      assert hd(events).payload == %{event: "issue_update", payload: payload}

      assert {:ok, :deduplicated} =
               Cympho.RateLimiting.dedup_broadcast(topic, "issue_update", payload)

      {:ok, events_after} = Cympho.EventStore.fetch_since(topic, nil)
      assert length(events_after) == 1
    end
  end

  describe "purge_topics_with_prefix/1" do
    test "drops every topic that starts with the given prefix and leaves others alone" do
      Cympho.EventStore.append("company:abc:issues", %{n: 1})
      Cympho.EventStore.append("company:abc:agents", %{n: 2})
      Cympho.EventStore.append("company:xyz:issues", %{n: 3})
      Cympho.EventStore.append("system:other", %{n: 4})

      deleted = Cympho.EventStore.purge_topics_with_prefix("company:abc:")

      assert deleted == 2
      assert Cympho.EventStore.count("company:abc:issues") == 0
      assert Cympho.EventStore.count("company:abc:agents") == 0
      assert Cympho.EventStore.count("company:xyz:issues") == 1
      assert Cympho.EventStore.count("system:other") == 1
    end

    test "returns zero when no topics match" do
      Cympho.EventStore.append("company:def:issues", %{n: 1})
      assert Cympho.EventStore.purge_topics_with_prefix("nothing-matches:") == 0
      assert Cympho.EventStore.count("company:def:issues") == 1
    end
  end
end
