defmodule CymphoWeb.ExecutionPolicyJSON do
  alias Cympho.ExecutionPolicies.ExecutionPolicy

  def index(%{execution_policies: policies}) do
    %{data: Enum.map(policies, &data/1)}
  end

  def show(%{execution_policy: %ExecutionPolicy{} = policy}) do
    %{data: data(policy)}
  end

  defp data(%ExecutionPolicy{} = policy) do
    %{
      id: policy.id,
      name: policy.name,
      stage_configs: policy.stage_configs,
      inserted_at: policy.inserted_at,
      updated_at: policy.updated_at
    }
  end
end