defmodule CymphoWeb.ExecutionPolicyLive.FormHelpers do
  @moduledoc false

  alias Cympho.ExecutionPolicies
  alias Cympho.ExecutionPolicies.ExecutionPolicy

  @default_stage_configs [
    %{"type" => "executor", "participant_id" => "engineer"},
    %{"type" => "reviewer", "participant_id" => "cto", "require_different_actor" => true},
    %{"type" => "approver", "participant_id" => "ceo", "require_human" => true}
  ]

  @stage_types ["executor", "reviewer", "approver"]
  @stage_indexes 1..3

  def default_stage_configs, do: @default_stage_configs

  def stage_indexes, do: Enum.to_list(@stage_indexes)

  def stage_type_options do
    [
      {"Executor", "executor"},
      {"Reviewer", "reviewer"},
      {"Approver", "approver"}
    ]
  end

  def stage_title(1), do: "Executor"
  def stage_title(2), do: "Reviewer"
  def stage_title(3), do: "Approver"
  def stage_title(_index), do: "Stage"

  def stage_hint(1), do: "Who does the work."
  def stage_hint(2), do: "Who reviews the work before approval."
  def stage_hint(3), do: "Who makes the final go/no-go call."
  def stage_hint(_index), do: "Stage participant and gates."

  def stage_configs_text(form) do
    form
    |> Phoenix.HTML.Form.input_value(:stage_configs)
    |> stage_configs_to_text()
  end

  def stage_configs_text_from_params(params) do
    case normalize_policy_params(params) do
      {:ok, %{"stage_configs" => stage_configs}} -> stage_configs_to_text(stage_configs)
      {:ok, %{stage_configs: stage_configs}} -> stage_configs_to_text(stage_configs)
      _ -> Map.get(params, "stage_configs") || "[]"
    end
  end

  def stage_value(form, index, key) do
    form
    |> stage_configs_from_form()
    |> Enum.at(index - 1, %{})
    |> stage_value(key)
    |> fallback(default_stage_value(index, key))
  end

  def stage_checked?(form, index, key) do
    form
    |> stage_configs_from_form()
    |> Enum.at(index - 1, %{})
    |> flag_enabled?(key)
  end

  def normalize_policy_params(%{"stage_configs" => stage_configs} = params) do
    cond do
      params["stage_input_mode"] == "json" ->
        with {:ok, normalized} <- parse_stage_configs(stage_configs) do
          {:ok, params |> drop_guided_stage_params() |> Map.put("stage_configs", normalized)}
        end

      guided_stage_params?(params) ->
        normalize_guided_policy_params(params)

      true ->
        with {:ok, normalized} <- parse_stage_configs(stage_configs) do
          {:ok, Map.put(params, "stage_configs", normalized)}
        end
    end
  end

  def normalize_policy_params(params) do
    if guided_stage_params?(params) do
      normalize_guided_policy_params(params)
    else
      {:ok, params}
    end
  end

  def form_error_changeset(%ExecutionPolicy{} = policy, params, message, action) do
    params =
      params
      |> Map.put("stage_configs", [])

    policy
    |> ExecutionPolicies.change_execution_policy(params)
    |> Ecto.Changeset.add_error(:stage_configs, message)
    |> Map.put(:action, action)
  end

  defp stage_configs_to_text(value) when is_binary(value), do: value
  defp stage_configs_to_text(nil), do: "[]"

  defp stage_configs_to_text(value) when is_list(value) do
    Jason.encode!(value, pretty: true)
  end

  defp stage_configs_to_text(_value), do: "[]"

  defp parse_stage_configs(value) when is_list(value), do: normalize_stages(value)

  defp parse_stage_configs(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> normalize_stages(decoded)
      {:error, _error} -> {:error, "must be valid JSON"}
    end
  end

  defp parse_stage_configs(_value), do: {:error, "must be a JSON array of stage objects"}

  defp normalize_guided_policy_params(params) do
    stages =
      Enum.map(@stage_indexes, fn index ->
        %{
          "type" => Map.get(params, "stage_#{index}_type"),
          "participant_id" => Map.get(params, "stage_#{index}_participant_id"),
          "require_different_actor" => Map.get(params, "stage_#{index}_require_different_actor"),
          "require_human" => Map.get(params, "stage_#{index}_require_human"),
          "auto_advance" => Map.get(params, "stage_#{index}_auto_advance")
        }
      end)

    with {:ok, normalized} <- normalize_stages(stages) do
      params =
        params
        |> drop_guided_stage_params()
        |> Map.drop(["stage_input_mode"])
        |> Map.put("stage_configs", normalized)

      {:ok, params}
    end
  end

  defp normalize_stages(stages) when is_list(stages) do
    stages
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {stage, index}, {:ok, normalized} ->
      case normalize_stage(stage, index) do
        {:ok, normalized_stage} -> {:cont, {:ok, normalized ++ [normalized_stage]}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
  end

  defp normalize_stages(_stages), do: {:error, "must be a JSON array of stage objects"}

  defp normalize_stage(stage, index) when is_map(stage) do
    type = stage_value(stage, "type")

    if type in @stage_types do
      {:ok,
       %{
         "type" => type,
         "participant_id" => stage_value(stage, "participant_id") || "",
         "require_different_actor" => flag_enabled?(stage, "require_different_actor"),
         "require_human" => flag_enabled?(stage, "require_human"),
         "auto_advance" => flag_enabled?(stage, "auto_advance")
       }}
    else
      {:error, "stage #{index} type must be executor, reviewer, or approver"}
    end
  end

  defp normalize_stage(_stage, index), do: {:error, "stage #{index} must be an object"}

  defp stage_value(stage, key) do
    Map.get(stage, key) || Map.get(stage, String.to_atom(key))
  end

  defp flag_enabled?(stage, key), do: truthy?(stage_value(stage, key))

  defp stage_configs_from_form(form) do
    case Phoenix.HTML.Form.input_value(form, :stage_configs) do
      value when is_list(value) -> value
      value when is_binary(value) -> value |> parse_stage_configs() |> unwrap_stages()
      _value -> @default_stage_configs
    end
  end

  defp unwrap_stages({:ok, stages}), do: stages
  defp unwrap_stages(_result), do: @default_stage_configs

  defp default_stage_value(index, "type") do
    @default_stage_configs
    |> Enum.at(index - 1, %{})
    |> Map.get("type", "executor")
  end

  defp default_stage_value(index, "participant_id") do
    @default_stage_configs
    |> Enum.at(index - 1, %{})
    |> Map.get("participant_id", "")
  end

  defp default_stage_value(_index, _key), do: nil

  defp guided_stage_params?(params) do
    Enum.any?(Map.keys(params), &String.starts_with?(&1, "stage_"))
  end

  defp drop_guided_stage_params(params) do
    keys =
      for index <- @stage_indexes,
          key <- [
            "type",
            "participant_id",
            "require_different_actor",
            "require_human",
            "auto_advance"
          ],
          do: "stage_#{index}_#{key}"

    Map.drop(params, ["stage_input_mode" | keys])
  end

  defp truthy?(value) when is_list(value), do: Enum.any?(value, &truthy?/1)
  defp truthy?(value), do: value in [true, "true", 1, "1", "on"]

  defp fallback(value, default) when value in [nil, ""], do: default
  defp fallback(value, _default), do: value
end
