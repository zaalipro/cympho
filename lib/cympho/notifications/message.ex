defmodule Cympho.Notifications.Message do
  @moduledoc """
  A notification message to be delivered through one or more channels.
  """

  @enforce_keys [:subject, :body, :user_id]
  defstruct [:subject, :body, :user_id, :metadata, :event_type]

  @type t :: %__MODULE__{
          subject: String.t(),
          body: String.t(),
          user_id: String.t(),
          metadata: map() | nil,
          event_type: String.t() | nil
        }

  def new(subject, body, user_id, metadata \\ %{}, event_type \\ nil) do
    %__MODULE__{
      subject: subject,
      body: body,
      user_id: user_id,
      metadata: metadata,
      event_type: event_type
    }
  end
end
