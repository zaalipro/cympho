defmodule Cympho.ExecutionPolicies do
  import Ecto.Query, warn: false
  alias Cympho.Repo
  alias Cympho.ExecutionPolicies.ExecutionPolicy

  def list_execution_policies do
    Repo.all(from p in ExecutionPolicy, order_by: [desc: p.inserted_at])
  end

  def get_execution_policy!(id), do: Repo.get!(ExecutionPolicy, id)

  def get_execution_policy(id) do
    case Repo.get(ExecutionPolicy, id) do
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
end