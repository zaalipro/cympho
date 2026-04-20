defmodule Cympho.Notifications.Channel do
  @moduledoc """
  Behaviour for notification channels.
  Implement this to add new notification delivery mechanisms.
  """

  alias Cympho.Notifications.Message

  @doc """
  Deliver a notification message through this channel.
  Returns :ok on success, {:error, reason} on failure.
  """
  @callback deliver(message :: Message.t(), config :: map()) :: :ok | {:error, term()}

  @doc """
  Check if this channel is properly configured and available.
  """
  @callback available?(config :: map()) :: boolean()

  @doc """
  Return the channel type identifier (e.g., :email, :webhook, :telegram).
  """
  @callback type() :: atom()
end