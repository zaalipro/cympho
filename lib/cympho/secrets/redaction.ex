defmodule Cympho.Secrets.Redaction do
  @moduledoc false

  @redacted_placeholder "[REDACTED]"

  # Credential-shaped substrings scrubbed from adapter diagnostics even when
  # the value is not a known runtime secret.
  @credential_patterns [
    {~r/((?:authorization|x-api-key)(?:\\?["'])?\s*[:=]\s*(?:\\?["'])?)(?:(?:bearer|basic|token)\s+)?[^\s"'\\,;]+/i,
     "\\1#{@redacted_placeholder}"},
    # NO_START_OPT: a caseless single-letter start makes PCRE2's global match
    # loop quadratic on large outputs (PCRE2Project/pcre2#1038).
    {~r/(*NO_START_OPT)\bbearer\s+[A-Za-z0-9._~+\/=-]{8,}/i, "Bearer #{@redacted_placeholder}"},
    {~r/\bsk-[A-Za-z0-9_-]{8,}/, @redacted_placeholder},
    {~r/((?:api[_-]?key|token|secret|password)(?:\\?["'])?\s*[:=]\s*(?:\\?["'])?)[^\s&"'\\,;]+/i,
     "\\1#{@redacted_placeholder}"},
    {~r/(:\/\/[^\s\/:@]+:)[^\s\/@]+@/, "\\1#{@redacted_placeholder}@"}
  ]

  # Env/config keys that name a credential (OPENCLAW_API_KEY, GITHUB_TOKEN,
  # PGPASSWORD, x-api-key). Matched on how the key ends, so flags such as
  # DISABLE_AUTH=1 or MAX_TOKENS=4096 are not taken for secrets.
  @secret_env_key ~r/(?:api[_-]?key|access[_-]key|secret[_-]key|private[_-]key|secret|token|passw(?:or)?d|credentials?|cookie|authorization|dsn|database_url)$/i

  def redact(input, secrets) when is_binary(input) and is_list(secrets) do
    Enum.reduce(secrets, input, fn secret, acc ->
      acc
      |> String.replace(secret, @redacted_placeholder)
      |> redact_json_escaped(secret)
    end)
  end

  def redact(input, _secrets), do: input

  # CLIs print JSON, where a quote, backslash or newline in a secret appears
  # escaped, so the escaped form is redacted too.
  defp redact_json_escaped(input, secret) do
    case Jason.encode(secret) do
      {:ok, "\"" <> encoded} ->
        escaped = binary_part(encoded, 0, byte_size(encoded) - 1)

        if escaped == secret,
          do: input,
          else: String.replace(input, escaped, @redacted_placeholder)

      _ ->
        input
    end
  end

  # Redacts known secret values and credential-shaped substrings inside a
  # binary, tuple, list or map, keeping the term's shape so callers can still
  # pattern-match on it.
  def redact_term(value, secrets) when is_binary(value) and is_list(secrets) do
    value |> redact(secrets) |> redact_credentials()
  end

  def redact_term(value, secrets) when is_tuple(value) do
    value |> Tuple.to_list() |> Enum.map(&redact_term(&1, secrets)) |> List.to_tuple()
  end

  # Head/tail recursion also covers improper lists such as iodata.
  def redact_term([head | tail], secrets) do
    [redact_term(head, secrets) | redact_term(tail, secrets)]
  end

  # Structs are maps, so this also reaches exception fields (e.g. a Mint
  # header value) while keeping the struct intact.
  def redact_term(value, secrets) when is_struct(value) do
    :maps.map(fn _key, nested -> redact_term(nested, secrets) end, value)
  end

  # A decoded error body or structured failure can carry a secret in a key.
  def redact_term(value, secrets) when is_map(value) do
    Map.new(value, fn {key, nested} ->
      {redact_term(key, secrets), redact_term(nested, secrets)}
    end)
  end

  def redact_term(value, _secrets), do: value

  def redact_credentials(input) when is_binary(input) do
    Enum.reduce(@credential_patterns, input, fn {pattern, replacement}, acc ->
      Regex.replace(pattern, acc, replacement)
    end)
  end

  def redact_credentials(input), do: input

  # Values of credential-named keys in a resolved runtime env or adapter
  # config, at any length, including nested maps such as HTTP `headers`.
  def secret_values(env) when is_map(env) and not is_struct(env) do
    Enum.flat_map(env, fn
      {_key, nested} when is_map(nested) ->
        secret_values(nested)

      {key, value} when is_binary(value) ->
        if String.trim(value) != "" and Regex.match?(@secret_env_key, to_string(key)),
          do: [value],
          else: []

      _other ->
        []
    end)
  end

  def secret_values(_env), do: []

  # Every value to redact from a run's diagnostics: each Secrets-store value
  # the run resolved (whatever its name), credential-named env and
  # adapter-config values, and the host/app credentials adapters fall back to.
  # Every nonblank line of a multi-line secret is added, however short, so a
  # cut partway through it cannot keep any of its lines. Longest first, so a
  # shorter overlapping secret never splits a longer one.
  def runtime_secrets(context) do
    (context_secrets(context) ++ fallback_credentials())
    |> Enum.flat_map(&[&1 | secret_lines(&1)])
    |> Enum.uniq()
    |> Enum.sort_by(&byte_size/1, :desc)
  end

  defp context_secrets(%{env: env, secret_keys: secret_keys, adapter_config: config})
       when is_map(env) do
    stored =
      for {_key, value} <- Map.take(env, secret_keys),
          is_binary(value) and String.trim(value) != "",
          do: value

    stored ++ secret_values(env) ++ secret_values(config)
  end

  defp context_secrets(_context), do: []

  # Credentials adapters use when the run's env and config have none
  # (ClaudeCode/AgentRunner, OpenClaw and Codex app config; Codex's and
  # Cursor's host env). They never pass through the runtime context.
  defp fallback_credentials do
    for value <- [
          Application.get_env(:cympho, :anthropic_api_key),
          Application.get_env(:cympho, :openclaw_api_key),
          Application.get_env(:cympho, :openai_api_key),
          System.get_env("OPENAI_API_KEY"),
          System.get_env("CURSOR_API_KEY")
        ],
        is_binary(value) and String.trim(value) != "",
        do: value
  end

  defp secret_lines(value) do
    value
    |> String.split(["\r\n", "\n"])
    |> Enum.reject(&(String.trim(&1) == ""))
  end

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
