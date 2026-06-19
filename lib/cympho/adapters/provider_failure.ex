defmodule Cympho.Adapters.ProviderFailure do
  @moduledoc """
  Detects provider-level failures that CLIs sometimes print while exiting 0.

  This guard is deliberately narrow. It scans raw adapter stdout/stderr for
  high-signal quota/rate-limit phrases, and only scans parsed maps when they
  are explicitly error-shaped.
  """

  @type category :: :rate_limited | :quota_exceeded | :provider_unavailable
  @type reason ::
          {:provider_failure, category(), String.t()}
          | {:runtime_failure, :permission_blocked, String.t()}

  @quota_needles [
    "insufficient_quota",
    "quota exceeded",
    "exceeded your current quota",
    "you exceeded your current quota",
    "billing hard limit",
    "monthly spending limit",
    "out of credits",
    "credits exhausted"
  ]

  @rate_limit_needles [
    "rate_limit_exceeded",
    "rate limit exceeded",
    "rate-limit exceeded",
    "too many requests",
    "status code 429",
    "http 429",
    "429 too many requests",
    "requests per minute",
    "tokens per minute"
  ]

  @provider_unavailable_needles [
    "status code 500",
    "status code 502",
    "status code 503",
    "status code 504",
    "status code 529",
    "http 500",
    "http 502",
    "http 503",
    "http 504",
    "http 529",
    "529 overloaded",
    "overloaded_error",
    "model is overloaded",
    "server overloaded",
    "provider overloaded",
    "service unavailable",
    "gateway timeout"
  ]

  @runtime_blocked_primary [
    "unable to proceed",
    "can't proceed",
    "cannot proceed",
    "i need approval",
    "need user approval",
    "requires user approval",
    "approval is required",
    "commands are being blocked",
    "blocked by permission",
    "blocked by permissions",
    "permission settings"
  ]

  @runtime_blocked_context [
    "approval",
    "blocked",
    "command",
    "permission",
    "permissions",
    "not allowed",
    "not permitted"
  ]

  @doc """
  Returns `:ok` when output looks usable, or a provider failure reason.
  """
  @spec detect(term()) :: :ok | {:error, reason()}
  def detect(output)

  def detect(output) when is_binary(output), do: detect_text(output)

  def detect(%{} = output) do
    text = flatten_text(output)

    if error_shaped?(output) do
      detect_text(text)
    else
      detect_runtime_blocked_text(text)
    end
  end

  def detect(_output), do: :ok

  defp detect_runtime_blocked_text(text) do
    clean = text |> to_string() |> String.trim()
    lower = String.downcase(clean)

    if contains_any?(lower, @runtime_blocked_primary) and
         contains_any?(lower, @runtime_blocked_context) do
      {:error, {:runtime_failure, :permission_blocked, snippet(clean)}}
    else
      :ok
    end
  end

  defp detect_text(text) do
    clean = text |> to_string() |> String.trim()
    lower = String.downcase(clean)
    runtime_blocked = detect_runtime_blocked_text(clean)

    cond do
      contains_any?(lower, @quota_needles) ->
        {:error, {:provider_failure, :quota_exceeded, snippet(clean)}}

      contains_any?(lower, @rate_limit_needles) ->
        {:error, {:provider_failure, :rate_limited, snippet(clean)}}

      contains_any?(lower, @provider_unavailable_needles) ->
        {:error, {:provider_failure, :provider_unavailable, snippet(clean)}}

      match?({:error, _reason}, runtime_blocked) ->
        runtime_blocked

      Regex.match?(~r/(^|\D)429(\D|$)/, lower) and String.contains?(lower, "openai") ->
        {:error, {:provider_failure, :rate_limited, snippet(clean)}}

      Regex.match?(~r/(^|\D)(500|502|503|504|529)(\D|$)/, lower) and
          contains_any?(lower, ["openai", "anthropic", "provider", "upstream"]) ->
        {:error, {:provider_failure, :provider_unavailable, snippet(clean)}}

      true ->
        :ok
    end
  end

  defp error_shaped?(map) do
    Map.has_key?(map, "error") or Map.has_key?(map, :error) or
      Map.get(map, "type") == "error" or Map.get(map, :type) == "error" or
      Map.get(map, "status") == "error" or Map.get(map, :status) == "error"
  end

  defp flatten_text(value) when is_binary(value), do: value

  defp flatten_text(value) when is_map(value) do
    value
    |> Map.values()
    |> Enum.map(&flatten_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  defp flatten_text(value) when is_list(value) do
    value
    |> Enum.map(&flatten_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  defp flatten_text(value) when value in [nil, ""], do: ""
  defp flatten_text(value), do: to_string(value)

  defp contains_any?(text, needles), do: Enum.any?(needles, &String.contains?(text, &1))

  defp snippet(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.slice(0, 500)
  end
end
