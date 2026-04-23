defmodule Cympho.GithubWebhook do
  @moduledoc """
  GitHub webhook signature verification.
  """
  def verify_signature(_body, _signature, nil), do: {:error, :unauthorized}
  def verify_signature(_body, nil, _secret), do: {:error, :unauthorized}

  def verify_signature(body, signature, secret)
      when is_binary(body) and is_binary(signature) and is_binary(secret) do
    expected = "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, secret, body), case: :lower)

    if Plug.Crypto.secure_compare(expected, signature) do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  def verify_signature(_, _, _), do: {:error, :unauthorized}
end
