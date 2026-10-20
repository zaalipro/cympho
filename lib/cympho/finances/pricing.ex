defmodule Cympho.Finances.Pricing do
  @moduledoc """
  Decides how a run's USD cost is known.

  A runtime reports a USD cost itself, only token counts, or nothing (see the
  adapter `usage_reporting/1` callback). Token counts become a cost only
  through per-agent pricing in the agent's config, keyed by the model a run
  actually uses:

      "pricing" => %{
        "gpt-5.4-mini" => %{
          "input_usd_per_mtok" => "0.75",
          "output_usd_per_mtok" => "4.50",
          "cached_input_usd_per_mtok" => "0.075"
        }
      }

  An agent on subscription or proxy billing sets `"billing_mode" => "flat_rate"`:
  runs on its own runtime profile count tokens at zero cost. Fallback profiles
  are not covered; their own pricing backs the agent's rates instead.

  Each run snapshots its pricing when it is created, and every settled run
  records `run_metadata["accounting"]["cost_source"]`: `reported`, `priced`,
  `flat_rate`, or `unknown`.
  """

  @mtok Decimal.new(1_000_000)

  @doc """
  Returns the pricing snapshot for a run of `model`, or nil when the agent
  config cannot price it.
  """
  @spec snapshot(map(), String.t() | nil, String.t() | nil) :: map() | nil
  def snapshot(agent_config, provider, model) when is_map(agent_config) do
    provenance = %{"provider" => provider, "model" => model}

    if flat_rate?(agent_config) do
      Map.put(provenance, "basis", "flat_rate")
    else
      case model_rates(agent_config, model) do
        nil -> nil
        rates -> rates |> Map.merge(provenance) |> Map.put("basis", "agent_pricing")
      end
    end
  end

  def snapshot(_agent_config, _provider, _model), do: nil

  @doc """
  True when a run on `adapter` with the resolved `adapter_config` and the
  run's pricing `snapshot` can be given a USD cost: the agent is flat-rate,
  the adapter reports a cost, or it reports tokens the snapshot prices.
  """
  @spec priceable?(module(), map(), map() | nil) :: boolean()
  def priceable?(adapter, adapter_config, snapshot) when is_map(adapter_config) do
    match?(%{"basis" => "flat_rate"}, snapshot) or
      case usage_reporting(adapter, adapter_config) do
        :cost -> true
        :tokens -> match?(%{"basis" => "agent_pricing"}, snapshot)
        _none -> false
      end
  end

  @doc """
  Settles a run's USD cost from its reported usage and pricing snapshot.

  Returns the cost (always a Decimal) and the accounting metadata recording
  how it was determined. A reported cost of zero is `reported`; a missing cost
  is priced from the snapshot when tokens were reported, else `unknown`.
  """
  @spec cost(map(), map() | nil) :: {Decimal.t(), map()}
  def cost(usage, snapshot) do
    reported = Map.get(usage, :cost_usd)
    cached = Map.get(usage, :cached_input_tokens) || 0

    {cost, source} =
      cond do
        match?(%{"basis" => "flat_rate"}, snapshot) ->
          {Decimal.new("0"), "flat_rate"}

        match?(%Decimal{}, reported) ->
          {reported, "reported"}

        match?(%{"basis" => "agent_pricing"}, snapshot) and tokens_reported?(usage) ->
          {priced(usage, cached, snapshot), "priced"}

        true ->
          {Decimal.new("0"), "unknown"}
      end

    accounting =
      if cached > 0,
        do: %{"cost_source" => source, "cached_input_tokens" => cached},
        else: %{"cost_source" => source}

    {cost, accounting}
  end

  @doc """
  True when `value` is a usable USD-per-million-tokens rate: a finite,
  non-negative number or numeric string.
  """
  @spec valid_rate?(term()) :: boolean()
  def valid_rate?(value), do: match?({:ok, _}, rate(value))

  @doc """
  What a run on `adapter` with `config` reports: `:cost`, `:tokens`, or
  `:none`.
  """
  @spec usage_reporting(module(), map()) :: :cost | :tokens | :none
  def usage_reporting(adapter, config) when is_atom(adapter) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :usage_reporting, 1),
      do: adapter.usage_reporting(config),
      else: :none
  end

  defp flat_rate?(config), do: config["billing_mode"] == "flat_rate"

  defp model_rates(config, model) when is_binary(model) and model != "" do
    with %{} = pricing <- config["pricing"],
         %{} = rates <- pricing[model],
         {:ok, input} <- rate(rates["input_usd_per_mtok"]),
         {:ok, output} <- rate(rates["output_usd_per_mtok"]),
         {:ok, cached} <- rate(rates["cached_input_usd_per_mtok"] || input) do
      %{
        "input_usd_per_mtok" => input,
        "output_usd_per_mtok" => output,
        "cached_input_usd_per_mtok" => cached
      }
    else
      _ -> nil
    end
  end

  defp model_rates(_config, _model), do: nil

  defp rate(value) when is_integer(value) and value >= 0, do: {:ok, Integer.to_string(value)}

  defp rate(value) when is_float(value) and value >= 0,
    do: {:ok, value |> Decimal.from_float() |> Decimal.to_string()}

  # Decimal.parse also accepts "Infinity" and "NaN"; neither can price a run.
  defp rate(value) when is_binary(value) do
    case Decimal.parse(String.trim(value)) do
      {decimal, ""} ->
        if Decimal.inf?(decimal) or Decimal.nan?(decimal) or Decimal.negative?(decimal),
          do: :error,
          else: {:ok, Decimal.to_string(decimal)}

      _ ->
        :error
    end
  end

  defp rate(_value), do: :error

  defp tokens_reported?(usage),
    do: (Map.get(usage, :input_tokens) || 0) + (Map.get(usage, :output_tokens) || 0) > 0

  # Input counts include cached input for every adapter that reports it
  # (Codex, OpenAI prompt_tokens, the summed Claude cache categories).
  defp priced(usage, cached, snapshot) do
    input = Map.get(usage, :input_tokens) || 0
    cached = min(cached, input)

    [
      {input - cached, snapshot["input_usd_per_mtok"]},
      {cached, snapshot["cached_input_usd_per_mtok"]},
      {Map.get(usage, :output_tokens) || 0, snapshot["output_usd_per_mtok"]}
    ]
    |> Enum.reduce(Decimal.new("0"), fn {tokens, rate}, acc ->
      Decimal.add(acc, Decimal.mult(tokens, Decimal.new(rate)))
    end)
    |> Decimal.div(@mtok)
  end
end
