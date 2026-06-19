defmodule Cympho.Adapters.RuntimeTimeout do
  @moduledoc """
  Normalizes adapter runtime timeout settings.

  Cympho historically used `timeout` in milliseconds because that is what
  BEAM timers expect. Operator-facing config may also use `timeout_ms` or
  `timeout_sec` so humans do not need to guess units.
  """

  @default_max_ms 3_600_000

  @type option ::
          {:default_ms, pos_integer()}
          | {:max_ms, pos_integer()}
          | {:field, String.t()}

  @spec resolve(map(), [option()]) :: pos_integer()
  def resolve(config, opts) when is_map(config) do
    default_ms = Keyword.fetch!(opts, :default_ms)

    case value(config) do
      nil -> default_ms
      {:ok, ms} -> ms
      {:error, _reason} -> default_ms
    end
  end

  def resolve(_config, opts), do: Keyword.fetch!(opts, :default_ms)

  @spec validate(map(), [option()]) :: :ok | {:error, String.t()}
  def validate(config, opts) when is_map(config) do
    max_ms = Keyword.get(opts, :max_ms, @default_max_ms)
    field = Keyword.get(opts, :field, "timeout")

    case value(config) do
      nil ->
        :ok

      {:ok, ms} when ms > 0 and ms <= max_ms ->
        :ok

      {:ok, ms} when ms <= 0 ->
        {:error, "#{field} must be positive; use a bounded value instead of 0"}

      {:ok, _ms} ->
        {:error, "#{field} must be less than or equal to #{max_ms} milliseconds"}

      {:error, :conflict} ->
        {:error, "#{field}, timeout_ms, and timeout_sec disagree; keep only one timeout unit"}

      {:error, :invalid} ->
        {:error, "#{field} must be a positive integer number of milliseconds or seconds"}
    end
  end

  def validate(_config, _opts), do: :ok

  defp value(config) do
    values =
      [
        {:timeout, fetch(config, :timeout)},
        {:timeout_ms, fetch(config, :timeout_ms)},
        {:timeout_sec, fetch(config, :timeout_sec)}
      ]
      |> Enum.reject(fn {_key, value} -> blank?(value) end)

    parsed = Enum.map(values, fn {key, value} -> {key, parse(key, value)} end)

    cond do
      parsed == [] ->
        nil

      Enum.any?(parsed, fn {_key, result} -> result == :error end) ->
        {:error, :invalid}

      true ->
        millis = Enum.map(parsed, fn {_key, {:ok, ms}} -> ms end)

        if millis |> Enum.uniq() |> length() == 1 do
          {:ok, hd(millis)}
        else
          {:error, :conflict}
        end
    end
  end

  defp fetch(config, key) do
    Map.get(config, key) || Map.get(config, Atom.to_string(key))
  end

  defp parse(:timeout_sec, value) do
    with {:ok, seconds} <- parse_integer(value) do
      {:ok, seconds * 1_000}
    end
  end

  defp parse(_key, value), do: parse_integer(value)

  defp parse_integer(value) when is_integer(value), do: {:ok, value}

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> {:ok, integer}
      _ -> :error
    end
  end

  defp parse_integer(_), do: :error

  defp blank?(value), do: value in [nil, ""]
end
