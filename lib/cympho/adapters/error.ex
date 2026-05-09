defmodule Cympho.Adapters.Error do
  @moduledoc """
  Normalises adapter/runtime failures into stable categories for storage and UI.
  """

  @categories ~w(
    missing_binary
    missing_credentials
    auth_failed
    timeout
    malformed_output
    no_output
    nonzero_exit
    unknown
  )a

  @type category ::
          :missing_binary
          | :missing_credentials
          | :auth_failed
          | :timeout
          | :malformed_output
          | :no_output
          | :nonzero_exit
          | :unknown

  @type t :: %__MODULE__{
          category: category(),
          title: String.t(),
          message: String.t(),
          detail: String.t() | nil,
          hint: String.t() | nil,
          adapter: String.t() | nil,
          raw: String.t() | nil
        }

  defstruct category: :unknown,
            title: "Unclassified failure",
            message: "The run failed before Cympho could classify the adapter error.",
            detail: nil,
            hint: "Review the raw error details and the agent adapter settings.",
            adapter: nil,
            raw: nil

  @doc """
  Returns a normalised adapter error for an arbitrary runtime failure reason.
  """
  @spec normalize(term(), keyword()) :: t()
  def normalize(reason, opts \\ [])

  def normalize(%__MODULE__{} = error, _opts), do: error

  def normalize(reason, opts) do
    adapter = opts |> Keyword.get(:adapter) |> normalise_adapter()
    raw = reason_to_string(reason)
    override_detail = opts[:detail]

    {category, title, message, detail, hint} =
      reason
      |> classify(raw, adapter)
      |> maybe_override_detail(override_detail)

    %__MODULE__{
      category: category,
      title: title,
      message: message,
      detail: clean_detail(detail),
      hint: hint,
      adapter: adapter,
      raw: truncate(raw)
    }
  end

  @doc """
  Rehydrates a normalised adapter error from run metadata.
  """
  @spec from_map(map() | nil) :: t() | nil
  def from_map(nil), do: nil

  def from_map(%__MODULE__{} = error), do: error

  def from_map(map) when is_map(map) do
    category = map_get(map, "category") |> normalise_category()

    %__MODULE__{
      category: category,
      title: map_get(map, "title") || category_title(category),
      message: map_get(map, "message") || category_message(category, nil),
      detail: clean_detail(map_get(map, "detail")),
      hint: map_get(map, "hint") || category_hint(category),
      adapter: map_get(map, "adapter"),
      raw: map_get(map, "raw")
    }
  end

  def from_map(_), do: nil

  @doc """
  Extracts a normalised adapter error from a run struct or run-like map.
  """
  @spec from_run(map() | nil) :: t() | nil
  def from_run(nil), do: nil

  def from_run(%{run_metadata: metadata} = run) do
    case metadata_error(metadata) do
      nil ->
        reason = Map.get(run, :error_reason)
        log_excerpt = Map.get(run, :log_excerpt)

        if present?(reason) or present?(log_excerpt) do
          normalise_run_failure(reason, log_excerpt, Map.get(run, :adapter))
        end

      stored ->
        from_map(stored)
    end
  end

  def from_run(_), do: nil

  @doc """
  Serialises a normalised error for storage in `heartbeat_runs.run_metadata`.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = error) do
    %{
      "category" => Atom.to_string(error.category),
      "title" => error.title,
      "message" => error.message,
      "detail" => error.detail,
      "hint" => error.hint,
      "adapter" => error.adapter,
      "raw" => error.raw
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  @doc """
  Compact sentence suitable for agent/system comments.
  """
  @spec comment(t() | term(), keyword()) :: String.t()
  def comment(error_or_reason, opts \\ [])

  def comment(%__MODULE__{} = error, _opts) do
    [error.title <> ": " <> error.message, error.hint]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end

  def comment(reason, opts), do: reason |> normalize(opts) |> comment()

  @doc """
  Builds fail-run attrs that keep the old fields useful and add structured metadata.
  """
  @spec run_attrs(term(), map(), keyword()) :: map()
  def run_attrs(reason, existing_metadata \\ %{}, opts \\ []) do
    error = normalize(reason, opts)

    metadata =
      existing_metadata
      |> ensure_map()
      |> Map.put("adapter_error", to_map(error))

    %{
      error_reason: error.title,
      log_excerpt: error.detail,
      run_metadata: metadata
    }
  end

  def categories, do: @categories

  defp classify({:exit_code, code, output}, _raw, adapter) do
    category_tuple(
      :nonzero_exit,
      "The #{adapter_label(adapter)} process exited with status #{code}.",
      output
    )
  end

  defp classify({:exit_code, code}, _raw, adapter) do
    category_tuple(
      :nonzero_exit,
      "The #{adapter_label(adapter)} process exited with status #{code}.",
      nil
    )
  end

  defp classify({:parse_error, output}, _raw, _adapter) do
    category_tuple(:malformed_output, nil, output)
  end

  defp classify({:http_error, status, body}, _raw, _adapter) when status in [401, 403] do
    category_tuple(:auth_failed, "The provider rejected the configured credential.", body)
  end

  defp classify({:http_error, reason}, raw, adapter), do: classify(reason, raw, adapter)

  defp classify({:request_failed, reason}, raw, adapter), do: classify(reason, raw, adapter)

  defp classify({:request_error, reason}, raw, adapter), do: classify(reason, raw, adapter)

  defp classify({:finch_error, message}, raw, adapter), do: classify(message, raw, adapter)

  defp classify({:config_invalid, reason}, raw, adapter), do: classify(reason, raw, adapter)

  defp classify(reason, _raw, adapter) when reason in [:timeout, :stall_timeout, :timed_out] do
    category_tuple(:timeout, timeout_message(reason, adapter), nil)
  end

  defp classify(reason, raw, adapter) when reason in [:no_command, :enoent] do
    classify_string(raw, adapter, :missing_binary)
  end

  defp classify(:no_output, raw, adapter), do: classify_string(raw, adapter, :no_output)

  defp classify(reason, raw, adapter) when reason in [nil, ""] do
    classify_string(raw, adapter, :no_output)
  end

  defp classify(_reason, raw, adapter), do: classify_string(raw, adapter)

  defp classify_string(raw, adapter, forced_category \\ nil) do
    text = raw |> to_string() |> String.trim()
    lower = String.downcase(text)

    category =
      forced_category ||
        cond do
          text == "" or lower == "nil" ->
            :no_output

          contains_any?(lower, [
            "command not found",
            "binary not found",
            "not found in path",
            "cli not found",
            "no such file or directory"
          ]) ->
            :missing_binary

          contains_any?(lower, [
            "api key not configured",
            "api key is not configured",
            "api key not set",
            "missing api key",
            "no api key",
            "anthropic_api_key not set",
            "openai_api_key not set",
            "missing provider configuration",
            "credentials not configured",
            "credential not configured"
          ]) ->
            :missing_credentials

          contains_any?(lower, [
            "unauthorized",
            "unauthorised",
            "authentication failed",
            "invalid api key",
            "invalid token",
            "401",
            "403 forbidden"
          ]) ->
            :auth_failed

          contains_any?(lower, ["timeout", "timed out", "stall_timeout"]) ->
            :timeout

          contains_any?(lower, [
            "parse_error",
            "parse error",
            "malformed",
            "invalid json",
            "json decode",
            "could not parse"
          ]) ->
            :malformed_output

          contains_any?(lower, ["no output", "empty output"]) ->
            :no_output

          Regex.match?(~r/exited with (status|code)\s+\d+/, lower) ->
            :nonzero_exit

          String.contains?(lower, "exit_code") ->
            :nonzero_exit

          true ->
            :unknown
        end

    detail = detail_from_string(category, text)

    category_tuple(category, category_message(category, adapter), detail)
  end

  defp detail_from_string(:nonzero_exit, text) do
    case String.split(text, ":", parts: 2) do
      [_prefix, detail] -> String.trim(detail)
      _ -> text
    end
  end

  defp detail_from_string(category, text)
       when category in [:unknown, :missing_binary, :missing_credentials],
       do: text

  defp detail_from_string(:malformed_output, text), do: text
  defp detail_from_string(:auth_failed, text), do: text
  defp detail_from_string(:timeout, _text), do: nil
  defp detail_from_string(:no_output, _text), do: nil

  defp category_tuple(category, message, detail) do
    {
      category,
      category_title(category),
      message || category_message(category, nil),
      detail,
      category_hint(category)
    }
  end

  defp category_title(:missing_binary), do: "Runtime command not found"
  defp category_title(:missing_credentials), do: "Credentials missing"
  defp category_title(:auth_failed), do: "Provider authentication failed"
  defp category_title(:timeout), do: "Run timed out"
  defp category_title(:malformed_output), do: "Malformed adapter output"
  defp category_title(:no_output), do: "No adapter output"
  defp category_title(:nonzero_exit), do: "Runtime exited with an error"
  defp category_title(:unknown), do: "Unclassified failure"

  defp category_message(:missing_binary, adapter),
    do: "#{adapter_label(adapter)} could not start because the configured command is unavailable."

  defp category_message(:missing_credentials, _adapter),
    do: "The adapter could not find the provider credentials it needs to run."

  defp category_message(:auth_failed, _adapter),
    do: "The provider rejected the configured credential."

  defp category_message(:timeout, adapter),
    do: "#{adapter_label(adapter)} did not finish before the timeout window."

  defp category_message(:malformed_output, _adapter),
    do: "The adapter returned output Cympho could not parse as a structured turn."

  defp category_message(:no_output, _adapter),
    do: "The adapter finished without producing usable output."

  defp category_message(:nonzero_exit, adapter),
    do: "#{adapter_label(adapter)} exited with a non-zero status."

  defp category_message(:unknown, _adapter),
    do: "The run failed before Cympho could classify the adapter error."

  defp category_hint(:missing_binary),
    do: "Install the CLI or update this agent's adapter command/path."

  defp category_hint(:missing_credentials),
    do: "Add the API key through agent runtime environment, secrets, or the wrapper command."

  defp category_hint(:auth_failed),
    do: "Verify the API key, base URL, model, and provider account access."

  defp category_hint(:timeout),
    do:
      "Increase the timeout, reduce the issue scope, or check whether the CLI is waiting for input."

  defp category_hint(:malformed_output),
    do: "Confirm the CLI is running in JSON/output mode and that wrappers do not print banners."

  defp category_hint(:no_output), do: "Check the CLI logs and wrapper stdout/stderr."

  defp category_hint(:nonzero_exit), do: "Open the log excerpt and fix the CLI or provider error."

  defp category_hint(:unknown), do: "Review the raw error details and the agent adapter settings."

  defp timeout_message(:stall_timeout, adapter),
    do: "#{adapter_label(adapter)} stopped producing output before the stall timeout."

  defp timeout_message(_reason, adapter), do: category_message(:timeout, adapter)

  defp maybe_override_detail({category, title, message, detail, hint}, override)
       when override in [nil, ""] do
    {category, title, message, detail, hint}
  end

  defp maybe_override_detail({category, title, message, detail, hint}, override) do
    {category, title, message, detail || override, hint}
  end

  defp metadata_error(metadata) when is_map(metadata) do
    Map.get(metadata, "adapter_error") || Map.get(metadata, :adapter_error)
  end

  defp metadata_error(_metadata), do: nil

  defp map_get(map, key) do
    Map.get(map, key) || Map.get(map, existing_atom_key(key))
  end

  defp existing_atom_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp existing_atom_key(key), do: key

  defp normalise_category(category) when is_atom(category) and category in @categories,
    do: category

  defp normalise_category(category) when is_binary(category) do
    atom = String.to_existing_atom(category)
    if atom in @categories, do: atom, else: :unknown
  rescue
    ArgumentError -> :unknown
  end

  defp normalise_category(_category), do: :unknown

  defp normalise_adapter(adapter) when adapter in [nil, ""], do: nil
  defp normalise_adapter(adapter), do: adapter |> to_string() |> String.replace("_", " ")

  defp adapter_label(nil), do: "The adapter"

  defp adapter_label(adapter),
    do: adapter |> to_string() |> String.replace("_", " ") |> String.capitalize()

  defp contains_any?(text, needles), do: Enum.any?(needles, &String.contains?(text, &1))

  defp reason_to_string(nil), do: ""
  defp reason_to_string(reason) when is_binary(reason), do: reason
  defp reason_to_string(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_to_string(reason), do: inspect(reason)

  defp clean_detail(value) when value in [nil, ""], do: nil
  defp clean_detail(value), do: value |> to_string() |> String.trim() |> truncate()

  defp truncate(nil), do: nil

  defp truncate(value) do
    value = to_string(value)

    if String.length(value) > 4_000 do
      String.slice(value, 0, 4_000) <> "\n…"
    else
      value
    end
  end

  defp ensure_map(map) when is_map(map), do: map
  defp ensure_map(_), do: %{}

  defp present?(value), do: value not in [nil, ""]

  defp normalise_run_failure(reason, log_excerpt, adapter) do
    error =
      reason
      |> normalize(adapter: adapter, detail: log_excerpt)
      |> maybe_combine_run_detail(reason, log_excerpt)

    log_error =
      if present?(log_excerpt) do
        normalize(log_excerpt, adapter: adapter, detail: combined_detail(reason, log_excerpt))
      end

    cond do
      actionable_log_error?(log_error) ->
        log_error

      error.category == :unknown and not is_nil(log_error) ->
        log_error

      true ->
        error
    end
  end

  defp actionable_log_error?(%__MODULE__{category: category}),
    do:
      category in [
        :missing_binary,
        :missing_credentials,
        :auth_failed,
        :timeout,
        :malformed_output
      ]

  defp actionable_log_error?(_), do: false

  defp maybe_combine_run_detail(%__MODULE__{} = error, reason, log_excerpt) do
    if present?(reason) and present?(log_excerpt) do
      %{error | detail: combined_detail(reason, log_excerpt)}
    else
      error
    end
  end

  defp combined_detail(reason, log_excerpt) do
    [reason, log_excerpt]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
    |> Enum.join("\n")
  end
end
