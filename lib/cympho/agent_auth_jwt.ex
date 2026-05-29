defmodule Cympho.AgentAuthJWT do
  @moduledoc """
  JSON Web Token (JWT) generation and verification for agent heartbeat authentication.

  Generates short-lived JWTs for agent heartbeats that include:
  - Agent ID
  - Run ID
  - Company ID
  - Expiration time

  Tokens are signed using HS256 and a secret key from configuration.
  """

  require Logger

  @token_ttl_seconds 300

  @doc """
  Generates a JWT for an agent heartbeat.

  ## Parameters
    - agent_id: The ID of the agent
    - run_id: The ID of the current run
    - company_id: The ID of the company

  ## Returns
    - {:ok, jwt_token} on success
    - {:error, reason} on failure
  """
  def generate_token(agent_id, run_id, company_id) do
    secret = get_secret_key()

    claims = %{
      "agent_id" => agent_id,
      "run_id" => run_id,
      "company_id" => company_id,
      "exp" => System.system_time(:second) + @token_ttl_seconds,
      "iat" => System.system_time(:second),
      "typ" => "agent_heartbeat"
    }

    case sign(claims, secret) do
      {:ok, token} -> {:ok, token}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Verifies a JWT token and returns the claims.

  ## Parameters
    - token: The JWT token to verify

  ## Returns
    - {:ok, claims} on success
    - {:error, reason} on failure
  """
  def verify_token(token) do
    secret = get_secret_key()

    with {:ok, token} <- trim_token(token),
         {:ok, claims} <- verify_and_decode(token, secret),
         :ok <- validate_token_type(claims),
         :ok <- validate_expiration(claims),
         :ok <- validate_future_token(claims) do
      {:ok, claims}
    else
      {:error, reason} = error ->
        Logger.debug("Failed to verify agent JWT: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Extracts the agent ID from verified token claims.
  """
  def get_agent_id(%{"agent_id" => agent_id}), do: {:ok, agent_id}
  def get_agent_id(_), do: {:error, :agent_id_not_found}

  @doc """
  Extracts the run ID from verified token claims.
  """
  def get_run_id(%{"run_id" => run_id}), do: {:ok, run_id}
  def get_run_id(_), do: {:error, :run_id_not_found}

  @doc """
  Extracts the company ID from verified token claims.
  """
  def get_company_id(%{"company_id" => company_id}), do: {:ok, company_id}
  def get_company_id(_), do: {:error, :company_id_not_found}

  # Private functions

  defp trim_token(token) when is_binary(token) do
    trimmed = String.trim(token)
    if byte_size(trimmed) > 0, do: {:ok, trimmed}, else: {:error, :empty_token}
  end

  defp trim_token(_), do: {:error, :invalid_token_format}

  defp sign(claims, secret) do
    try do
      header = %{"alg" => "HS256", "typ" => "JWT"}
      encoded_header = base64_url_encode(Jason.encode!(header))
      encoded_claims = base64_url_encode(Jason.encode!(claims))
      signing_input = encoded_header <> "." <> encoded_claims
      signature = hmac_sha256(signing_input, secret)
      token = signing_input <> "." <> base64_url_encode(signature)
      {:ok, token}
    rescue
      e -> {:error, {:encoding_failed, Exception.message(e)}}
    end
  end

  defp verify_and_decode(token, secret) do
    with [encoded_header, encoded_claims, encoded_signature] <- String.split(token, "."),
         :ok <- verify_signature(encoded_header, encoded_claims, encoded_signature, secret),
         {:ok, _header} <- base64_url_decode(encoded_header),
         {:ok, claims} <- base64_url_decode(encoded_claims) do
      case Jason.decode(claims) do
        {:ok, decoded_claims} when is_map(decoded_claims) -> {:ok, decoded_claims}
        _ -> {:error, :invalid_claims_format}
      end
    else
      _ -> {:error, :invalid_token_format}
    end
  end

  defp verify_signature(encoded_header, encoded_claims, encoded_signature, secret) do
    signing_input = encoded_header <> "." <> encoded_claims

    case base64_url_decode(encoded_signature) do
      {:ok, signature} ->
        expected_signature = hmac_sha256(signing_input, secret)

        if constant_time_compare(signature, expected_signature) do
          :ok
        else
          {:error, :invalid_signature}
        end

      _ ->
        {:error, :invalid_signature_format}
    end
  end

  defp validate_token_type(%{"typ" => "agent_heartbeat"}), do: :ok
  defp validate_token_type(_), do: {:error, :invalid_token_type}

  defp validate_expiration(%{"exp" => exp}) when is_integer(exp) do
    current_time = System.system_time(:second)
    if exp > current_time, do: :ok, else: {:error, :token_expired}
  end

  defp validate_expiration(_), do: {:error, :missing_expiration}

  defp validate_future_token(%{"iat" => iat}) when is_integer(iat) do
    current_time = System.system_time(:second)
    # Allow for some clock skew (up to 60 seconds in the future)
    if iat <= current_time + 60, do: :ok, else: {:error, :token_from_future}
  end

  defp validate_future_token(_), do: {:error, :missing_issued_at}

  defp get_secret_key do
    Application.fetch_env!(:cympho, :agent_jwt_secret)
  end

  defp base64_url_encode(data) do
    data
    |> Base.encode64()
    |> String.replace_trailing("=", "")
    |> String.replace("+", "-")
    |> String.replace("/", "_")
  end

  defp base64_url_decode(data) do
    with padded <- String.replace(data, "-", "+") |> String.replace("_", "/"),
         padded <- pad_base64(padded),
         {:ok, decoded} <- Base.decode64(padded) do
      {:ok, decoded}
    else
      _ -> {:error, :invalid_base64}
    end
  end

  defp pad_base64(data) do
    case rem(byte_size(data), 4) do
      0 -> data
      2 -> data <> "=="
      3 -> data <> "="
      _ -> data
    end
  end

  defp hmac_sha256(data, secret) do
    :crypto.mac(:hmac, :sha256, secret, data)
  end

  defp constant_time_compare(a, b) do
    Plug.Crypto.secure_compare(pad_to_length(a, byte_size(b)), b)
  end

  defp pad_to_length(data, target) do
    current = byte_size(data)
    if current >= target, do: data, else: data <> :binary.copy(<<0>>, target - current)
  end
end
