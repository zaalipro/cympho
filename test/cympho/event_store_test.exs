defmodule Cympho.EventStoreTest do
  use ExUnit.Case, async: false

  setup do
    # Start EventStore if not already running (app may not start in test mode)
    case GenServer.whereis(Cympho.EventStore) do
      nil ->
        {:ok, _pid} = Cympho.EventStore.start_link(max_events_per_topic: 5)
        on_exit(fn -> GenServer.stop(Cympho.EventStore, :normal) end)
      _pid ->
        :ok
    end
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
end
