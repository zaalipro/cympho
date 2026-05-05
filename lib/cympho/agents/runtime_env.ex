defmodule Cympho.Agents.RuntimeEnv do
  @moduledoc """
  Helpers for the per-agent environment variable map stored in
  `agent.runtime_config["env"]`.

  Used by the agent form (textarea ↔ map) and by `Cympho.Runtime` when
  assembling the env that gets passed to the adapter subprocess.
  """

  @doc """
  Returns the env map stored on the agent's `runtime_config`.

  Always returns a string-keyed string-valued map. Non-string entries are
  coerced; nil/missing yields `%{}`.
  """
  @spec from_agent(map() | nil) :: %{optional(String.t()) => String.t()}
  def from_agent(nil), do: %{}

  def from_agent(%{runtime_config: %{} = runtime_config}) do
    from_runtime_config(runtime_config)
  end

  def from_agent(_), do: %{}

  @spec from_runtime_config(map()) :: %{optional(String.t()) => String.t()}
  def from_runtime_config(%{} = runtime_config) do
    case Map.get(runtime_config, "env") || Map.get(runtime_config, :env) do
      %{} = env -> normalise(env)
      _ -> %{}
    end
  end

  def from_runtime_config(_), do: %{}

  @doc """
  Renders an env map as `KEY=VALUE` lines, sorted alphabetically.
  """
  @spec to_text(map() | nil) :: String.t()
  def to_text(nil), do: ""

  def to_text(map) when is_map(map) do
    map
    |> normalise()
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Enum.map_join("\n", fn {k, v} -> "#{k}=#{v}" end)
  end

  @doc """
  Parses a textarea value into a string-keyed map.

  Lines are trimmed; blank lines and lines starting with `#` are ignored.
  An entry without `=` is dropped. The key portion may not contain spaces
  or `=`. The value is taken verbatim after the first `=`, with a single
  pair of surrounding double or single quotes stripped if present.
  """
  @spec parse_text(String.t() | nil) :: %{optional(String.t()) => String.t()}
  def parse_text(nil), do: %{}
  def parse_text(""), do: %{}

  def parse_text(text) when is_binary(text) do
    text
    |> String.split(["\r\n", "\n"], trim: false)
    |> Enum.reduce(%{}, fn line, acc ->
      trimmed = String.trim(line)

      cond do
        trimmed == "" -> acc
        String.starts_with?(trimmed, "#") -> acc
        true -> maybe_put(acc, trimmed)
      end
    end)
  end

  defp maybe_put(acc, line) do
    case String.split(line, "=", parts: 2) do
      [key, value] ->
        key = String.trim(key)

        if valid_key?(key) do
          Map.put(acc, key, unquote_value(String.trim_trailing(value)))
        else
          acc
        end

      _ ->
        acc
    end
  end

  defp valid_key?(key) do
    key != "" and not String.contains?(key, [" ", "\t"])
  end

  defp unquote_value(value) do
    cond do
      starts_and_ends_with?(value, "\"") -> String.slice(value, 1..-2//1)
      starts_and_ends_with?(value, "'") -> String.slice(value, 1..-2//1)
      true -> value
    end
  end

  defp starts_and_ends_with?(value, char) do
    String.length(value) >= 2 and String.starts_with?(value, char) and
      String.ends_with?(value, char)
  end

  defp normalise(map) do
    Map.new(map, fn {k, v} -> {to_string(k), to_string_safe(v)} end)
  end

  defp to_string_safe(nil), do: ""
  defp to_string_safe(v) when is_binary(v), do: v
  defp to_string_safe(v), do: to_string(v)
end
