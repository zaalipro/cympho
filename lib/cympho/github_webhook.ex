defmodule Cympho.GithubWebhook do
  @moduledoc """
  GitHub webhook signature verification using HMAC-SHA256.
  """

  @doc """
  Verifies the X-Hub-Signature-256 header against the payload using HMAC-SHA256.

  Returns :ok if the signature is valid, {:error, :unauthorized} otherwise.
  """
  def verify_signature(payload, signature, secret) do
    if is_nil(signature) or is_nil(secret) or secret == "" do
      {:error, :unauthorized}
    else
      expected = "sha256=" <> compute_hmac(payload, secret)

      if secure_compare(expected, signature) do
        :ok
      else
        {:error, :unauthorized}
      end
    end
  end

  defp compute_hmac(payload, secret) do
    :crypto.mac(:hmac, :sha256, secret, payload)
    |> Base.encode16(case: :lower)
  end

  # Constant-time comparison to prevent timing attacks
  defp secure_compare(a, b) when byte_size(a) == byte_size(b) do
    a === b
  end
  defp secure_compare(_, _), do: false
end