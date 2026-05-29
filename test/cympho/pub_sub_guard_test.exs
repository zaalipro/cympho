defmodule Cympho.PubSubGuardTest do
  @moduledoc """
  PR 1 (REQ-001): the guard must refuse broadcasts on malformed multi-tenant
  topics (the shape produced by interpolating a nil company_id) and deliver
  normally on well-formed company-scoped topics.
  """
  use ExUnit.Case, async: true

  alias Cympho.PubSubGuard

  describe "broadcast/2" do
    test "refuses a topic built from a nil company_id" do
      company_id = nil
      topic = "company:#{company_id}:issues"

      assert {:error, :malformed_topic} = PubSubGuard.broadcast(topic, {:noop, 1})
    end

    test "refuses a non-binary topic" do
      assert {:error, :malformed_topic} = PubSubGuard.broadcast(:not_a_topic, {:noop, 1})
    end

    test "delivers on a well-formed company-scoped topic" do
      company_id = "11111111-1111-1111-1111-111111111111"
      topic = "company:#{company_id}:issues"
      Phoenix.PubSub.subscribe(Cympho.PubSub, topic)

      assert :ok = PubSubGuard.broadcast(topic, {:work_product_created, %{id: "x"}})
      assert_receive {:work_product_created, %{id: "x"}}
    end
  end
end
