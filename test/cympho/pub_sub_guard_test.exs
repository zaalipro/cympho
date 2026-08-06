defmodule Cympho.PubSubGuardTest do
  @moduledoc """
  Fail-closed multi-tenant PubSub: refuse company:: topics, no-op on nil
  company_id via company_broadcast/3, deliver on well-formed topics.
  """
  use ExUnit.Case, async: true

  alias Cympho.PubSubGuard

  describe "broadcast/2" do
    test "refuses a topic built from a nil company_id" do
      company_id = nil
      topic = "company:#{company_id}:issues"

      assert topic == "company::issues"
      assert {:error, :malformed_topic} = PubSubGuard.broadcast(topic, {:noop, 1})
    end

    test "refuses any topic containing ::" do
      assert {:error, :malformed_topic} =
               PubSubGuard.broadcast("company::approvals", {:approval_created, %{}})

      assert {:error, :malformed_topic} =
               PubSubGuard.broadcast("company::documents", {:document_created, %{}})

      assert {:error, :malformed_topic} =
               PubSubGuard.broadcast("company::activities", {:activity_created, %{}})
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

    test "delivers on intentional system topics" do
      topic = "system:decisions"
      Phoenix.PubSub.subscribe(Cympho.PubSub, topic)

      assert :ok = PubSubGuard.broadcast(topic, {:decision_created, %{id: "d1"}})
      assert_receive {:decision_created, %{id: "d1"}}
    end
  end

  describe "company_broadcast/3" do
    test "delivers on a valid company_id" do
      company_id = "22222222-2222-2222-2222-222222222222"
      Phoenix.PubSub.subscribe(Cympho.PubSub, "company:#{company_id}:budgets")

      assert :ok =
               PubSubGuard.company_broadcast(company_id, "budgets", {:budget_created, %{id: "b"}})

      assert_receive {:budget_created, %{id: "b"}}
    end

    test "nil company_id is a no-op (does not publish company::)" do
      # If a leak were published, a subscriber on the malformed topic would hear it.
      Phoenix.PubSub.subscribe(Cympho.PubSub, "company::approvals")
      Phoenix.PubSub.subscribe(Cympho.PubSub, "approvals")

      assert :ok = PubSubGuard.company_broadcast(nil, "approvals", {:approval_created, :leak})

      refute_receive {:approval_created, :leak}, 50
    end

    test "empty company_id is a no-op" do
      Phoenix.PubSub.subscribe(Cympho.PubSub, "company::documents")

      assert :ok = PubSubGuard.company_broadcast("", "documents", {:document_created, :leak})

      refute_receive {:document_created, :leak}, 50
    end

    test "empty suffix is a no-op" do
      company_id = "33333333-3333-3333-3333-333333333333"
      Phoenix.PubSub.subscribe(Cympho.PubSub, "company:#{company_id}:")

      assert :ok = PubSubGuard.company_broadcast(company_id, "", {:noop, 1})

      refute_receive {:noop, 1}, 50
    end
  end

  describe "domain subscribe fail-closed" do
    test "Issues/Events/Agents subscribe refuse blank company_id" do
      assert :ok = Cympho.Issues.subscribe(nil)
      assert :ok = Cympho.Issues.subscribe("")
      assert :ok = CymphoWeb.Events.subscribe_to_issues(nil)
      assert :ok = CymphoWeb.Events.subscribe_to_issues("")
      assert :ok = CymphoWeb.Events.subscribe_to_runs(nil)
      assert :ok = Cympho.Agents.subscribe(nil)
      assert :ok = Cympho.Agents.subscribe("")
      assert :ok = Cympho.Projects.subscribe(nil)
      assert :ok = Cympho.Projects.subscribe("")
    end
  end

  describe "RateLimiting.dedup_pubsub/3" do
    test "refuses company:: topics via PubSubGuard" do
      assert {:error, :malformed_topic} =
               Cympho.RateLimiting.dedup_pubsub(
                 Cympho.PubSub,
                 "company::activities",
                 {:activity_created, %{id: "a"}}
               )
    end

    test "delivers well-formed company topics" do
      company_id = "44444444-4444-4444-4444-444444444444"
      topic = "company:#{company_id}:activities"
      Phoenix.PubSub.subscribe(Cympho.PubSub, topic)

      assert :ok =
               Cympho.RateLimiting.dedup_pubsub(
                 Cympho.PubSub,
                 topic,
                 {:activity_created, %{id: "a1"}}
               )

      assert_receive {:activity_created, %{id: "a1"}}
    end
  end

  describe "RateLimiting.dedup_broadcast/3" do
    test "refuses company:: Endpoint topics (nil company_id)" do
      assert {:error, :malformed_topic} =
               Cympho.RateLimiting.dedup_broadcast(
                 "company::issues",
                 "issue_update",
                 %{id: "leak"}
               )

      assert {:error, :malformed_topic} =
               Cympho.RateLimiting.dedup_broadcast(
                 "company::runs",
                 "run_status",
                 %{id: "leak"}
               )
    end

    test "refuses non-binary topics" do
      assert {:error, :malformed_topic} =
               Cympho.RateLimiting.dedup_broadcast(:not_a_topic, "event", %{})
    end
  end
end
