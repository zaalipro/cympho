defmodule Cympho.WebhookDedupTest do
  use ExUnit.Case, async: false

  alias Cympho.WebhookDedup

  setup do
    WebhookDedup.reset()
    :ok
  end

  describe "check_and_mark/1" do
    test "returns :fresh for a new delivery id and :duplicate on the second call" do
      id = "delivery-#{System.unique_integer([:positive])}"
      assert WebhookDedup.check_and_mark(id) == :fresh
      assert WebhookDedup.check_and_mark(id) == :duplicate
      assert WebhookDedup.check_and_mark(id) == :duplicate
    end

    test "different ids do not interfere" do
      assert WebhookDedup.check_and_mark("a") == :fresh
      assert WebhookDedup.check_and_mark("b") == :fresh
      assert WebhookDedup.check_and_mark("a") == :duplicate
      assert WebhookDedup.check_and_mark("b") == :duplicate
    end

    test "treats nil and empty id as :fresh (no dedup possible without an id)" do
      assert WebhookDedup.check_and_mark(nil) == :fresh
      assert WebhookDedup.check_and_mark("") == :fresh
      # Calling again with nil is still :fresh — there is no key to look up.
      assert WebhookDedup.check_and_mark(nil) == :fresh
    end

    test "concurrent calls with the same id resolve to exactly one :fresh" do
      id = "race-#{System.unique_integer([:positive])}"

      results =
        1..50
        |> Enum.map(fn _ ->
          Task.async(fn -> WebhookDedup.check_and_mark(id) end)
        end)
        |> Enum.map(&Task.await/1)

      fresh = Enum.count(results, &(&1 == :fresh))
      duplicate = Enum.count(results, &(&1 == :duplicate))

      assert fresh == 1
      assert duplicate == 49
    end
  end
end
