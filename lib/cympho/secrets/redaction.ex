defmodule Cympho.Secrets.Redaction do
  @moduledoc false

  @redacted_placeholder "[REDACTED]"

  def redact(input, secrets) when is_binary(input) and is_list(secrets) do
    Enum.reduce(secrets, input, fn secret, acc ->
      String.replace(acc, secret, @redacted_placeholder)
    end)
  end

  def redact(input, _secrets), do: input

  def redact_map(map, secret_keys) when is_map(map) and is_list(secret_keys) do
    Map.new(map, fn {key, value} ->
      if key in secret_keys do
        {key, @redacted_placeholder}
      else
        {key, redact_value(value, secret_keys)}
      end
    end)
  end

  defp redact_value(value, secret_keys) when is_map(value) do
    redact_map(value, secret_keys)
  end

  defp redact_value(value, _secret_keys), do: value

  def redact_log(log_entry, secrets) when is_binary(log_entry) and is_list(secrets) do
    redact(log_entry, secrets)
  end
end
