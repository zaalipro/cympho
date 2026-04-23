defmodule Cympho.Notifications.EmailChannel do
  @moduledoc """
  Email notification channel using Swoosh.
  """

  alias Cympho.Notifications.Channel
  alias Cympho.Notifications.Message

  @behaviour Channel

  @impl Channel
  def deliver(%Message{} = message, config) do
    email = config[:email]

    if is_binary(email) and String.contains?(email, "@") do
      email =
        Swoosh.Email.new()
        |> Swoosh.Email.to(email)
        |> Swoosh.Email.from(config[:from_address] || "noreply@cympho.app")
        |> Swoosh.Email.subject(message.subject)
        |> Swoosh.Email.text_body(message.body)

      case Cympho.Mailer.deliver(email) do
        {:ok, _email} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :invalid_email}
    end
  end

  @impl Channel
  def available?(config) do
    email = config[:email]
    is_binary(email) and String.contains?(email, "@")
  end

  @impl Channel
  def type, do: :email
end
