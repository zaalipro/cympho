defmodule Cympho.PubSubGuard do
  @moduledoc """
  Wrapper around `Phoenix.PubSub.broadcast/3` that refuses to publish on
  malformed multi-tenant topics — specifically those produced by
  interpolating a `nil` `company_id`. The default behavior in Phoenix is to
  silently turn `"company:#{nil}:foo"` into `"company::foo"`, which any
  subscriber that built the same malformed topic would receive — a
  cross-tenant leak waiting to happen.

  Use `broadcast/2` (or `broadcast/3` with an explicit pubsub) instead of
  calling Phoenix.PubSub directly anywhere a `company_id` is interpolated
  into the topic.
  """

  require Logger

  @default_pubsub Cympho.PubSub
  @malformed_marker "::"

  def broadcast(topic, message), do: broadcast(@default_pubsub, topic, message)

  def broadcast(pubsub, topic, message) when is_binary(topic) do
    cond do
      String.contains?(topic, @malformed_marker) ->
        Logger.warning(
          "[PubSubGuard] refusing broadcast on malformed topic #{inspect(topic)} — likely nil company_id"
        )

        {:error, :malformed_topic}

      String.starts_with?(topic, "company:") and String.contains?(topic, "company::") ->
        Logger.warning(
          "[PubSubGuard] refusing broadcast on malformed company topic #{inspect(topic)}"
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
