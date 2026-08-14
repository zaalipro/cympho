defmodule Cympho.ExecutionPolicies do
  @moduledoc """
  The ExecutionPolicies context.
  """
  import Ecto.Query, warn: false
  alias Cympho.Repo
  alias Cympho.ExecutionPolicies.ExecutionPolicy

  def list_execution_policies(company_id) do
    Repo.all(
      from p in ExecutionPolicy,
        where: p.company_id == ^company_id,
        order_by: [desc: p.inserted_at]
    )
  end

  def list_execution_policies_page(company_id, opts \\ []) do
    ExecutionPolicy
    |> where([p], p.company_id == ^company_id)
    |> Cympho.Pagination.page(
      limit: Keyword.get(opts, :limit, 50),
      after: Keyword.get(opts, :after)
    )
  end

  def policy_posture(policies) do
    policies = Enum.to_list(policies)
    policy_summaries = Enum.map(policies, &policy_summary/1)

    %{
      total: length(policies),
      stage_count: Enum.sum(Enum.map(policy_summaries, & &1.stage_count)),
      ready_count: Enum.count(policy_summaries, &(&1.status == :ready)),
      empty_count: Enum.count(policy_summaries, &(&1.stage_count == 0)),
      missing_participant_count:
        Enum.count(policy_summaries, &(&1.missing_participant_count > 0)),
      review_gate_count: Enum.count(policy_summaries, & &1.has_review_gate?),
      approver_gate_count: Enum.count(policy_summaries, & &1.has_approver_gate?),
      human_gate_count: Enum.count(policy_summaries, & &1.has_human_gate?),
      different_actor_count: Enum.count(policy_summaries, & &1.has_different_actor_gate?),
      auto_advance_count: Enum.count(policy_summaries, &(&1.auto_advance_count > 0)),
      attention_policy: Enum.find(policy_summaries, &(&1.status != :ready)),
      policies: policy_summaries
    }
  end

  def policy_summary(%ExecutionPolicy{} = policy) do
    stages = policy.stage_configs || []
    stage_types = Enum.map(stages, &stage_type/1)
    missing_participant_count = Enum.count(stages, &(participant_id(&1) in [nil, ""]))

    status =
      cond do
        stages == [] -> :empty
        missing_participant_count > 0 -> :missing_participant
        not Enum.any?(stage_types, &(&1 in ["reviewer", "approver"])) -> :no_review_gate
        true -> :ready
      end

    %{
      id: policy.id,
      name: policy.name,
      status: status,
      stage_count: length(stages),
      stage_types: stage_types,
      missing_participant_count: missing_participant_count,
      has_review_gate?: Enum.any?(stage_types, &(&1 == "reviewer")),
      has_approver_gate?: Enum.any?(stage_types, &(&1 == "approver")),
      has_human_gate?: Enum.any?(stages, &flag_enabled?(&1, "require_human")),
      has_different_actor_gate?: Enum.any?(stages, &flag_enabled?(&1, "require_different_actor")),
      auto_advance_count: Enum.count(stages, &flag_enabled?(&1, "auto_advance"))
    }
  end

  def get_execution_policy!(id), do: Repo.get!(ExecutionPolicy, id)

  def get_execution_policy(id) do
    case Repo.get(ExecutionPolicy, id) do
      nil -> {:error, :not_found}
      policy -> {:ok, policy}
    end
  end

  def get_company_execution_policy(company_id, id) do
    case Repo.one(
           from p in ExecutionPolicy,
             where: p.id == ^id and p.company_id == ^company_id
         ) do
      nil -> {:error, :not_found}
      policy -> {:ok, policy}
    end
  end

  def create_execution_policy(attrs \\ %{}) do
    %ExecutionPolicy{}
    |> ExecutionPolicy.changeset(attrs)
    |> Repo.insert()
  end

  def update_execution_policy(%ExecutionPolicy{} = policy, attrs) do
    policy
    |> ExecutionPolicy.changeset(attrs)
    |> Repo.update()
  end

  def delete_execution_policy(%ExecutionPolicy{} = policy) do
    Repo.delete(policy)
  end

  def change_execution_policy(%ExecutionPolicy{} = policy, attrs \\ %{}) do
    ExecutionPolicy.changeset(policy, attrs)
  end

  defp stage_type(stage) when is_map(stage) do
    stage
    |> map_value("type")
    |> to_string()
  end

  defp stage_type(_stage), do: ""

  defp participant_id(stage) when is_map(stage), do: map_value(stage, "participant_id")
  defp participant_id(_stage), do: nil

  defp flag_enabled?(stage, key) when is_map(stage), do: map_value(stage, key) in [true, "true"]
  defp flag_enabled?(_stage, _key), do: false

  defp map_value(map, key), do: Map.get(map, key) || Map.get(map, String.to_atom(key))
end
