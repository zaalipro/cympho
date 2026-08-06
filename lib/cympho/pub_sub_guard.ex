defmodule Cympho.PubSubGuard do
  @moduledoc """
  Wrapper around `Phoenix.PubSub.broadcast/3` that refuses to publish on
  malformed multi-tenant topics — specifically those produced by
  interpolating a `nil` `company_id`. The default behavior in Phoenix is to
  silently turn `"company:#{nil}:foo"` into `"company::foo"`, which any
  subscriber that built the same malformed topic would receive — a
  cross-tenant leak waiting to happen.

  Prefer `company_broadcast/3` for tenant-scoped publishes: a missing
  `company_id` is a silent no-op (fail-closed). Use `broadcast/2` (or
  `broadcast/3` with an explicit pubsub) for non-company topics such as
  `system:decisions`.
  """

  require Logger

  @default_pubsub Cympho.PubSub
  @malformed_marker "::"

  @doc """
  Broadcast on a company-scoped topic `"company:\#{company_id}:\#{suffix}"`.

  Returns `:ok` when delivered. When `company_id` is missing/blank, returns
  `:ok` without publishing (fail-closed multi-tenancy — never emit `company::`).
  """
  def company_broadcast(company_id, suffix, message)
      when is_binary(company_id) and company_id != "" and is_binary(suffix) and suffix != "" do
    broadcast("company:#{company_id}:#{suffix}", message)
  end

  def company_broadcast(_company_id, _suffix, _message), do: :ok

  def broadcast(topic, message), do: broadcast(@default_pubsub, topic, message)

  def broadcast(pubsub, topic, message) when is_binary(topic) do
    cond do
      String.contains?(topic, @malformed_marker) ->
        Logger.warning(
          "[PubSubGuard] refusing broadcast on malformed topic #{inspect(topic)} — likely nil company_id"
        )

        {:error, :malformed_topic}

      true ->
        Phoenix.PubSub.broadcast(pubsub, topic, message)
    end
  end

  def broadcast(_pubsub, topic, _message) do
    Logger.warning("[PubSubGuard] refusing broadcast with non-binary topic: #{inspect(topic)}")
    {:error, :malformed_topic}
  end
end
