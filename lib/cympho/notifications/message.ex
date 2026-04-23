defmodule Cympho.Notifications.Message do
  @moduledoc """
  A notification message to be delivered through one or more channels.
  """

  @enforce_keys [:subject, :body, :user_id]
  defstruct [:subject, :body, :user_id, :metadata]

  @type t :: %__MODULE__{
          subject: String.t(),
          body: String.t(),
          user_id: String.t(),
          metadata: map() | nil
        }

  def new(subject, body, user_id, metadata \\ %{}) do
    %__MODULE__{
      subject: subject,
      body: body,
      user_id: user_id,
      metadata: metadata
    }
  end
end
