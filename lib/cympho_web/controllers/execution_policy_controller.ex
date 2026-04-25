defmodule CymphoWeb.ExecutionPolicyController do
  use CymphoWeb, :controller

  alias Cympho.ExecutionPolicies
  alias Cympho.ExecutionPolicies.ExecutionPolicy

  action_fallback CymphoWeb.FallbackController

  def index(conn, _params) do
    policies = ExecutionPolicies.list_execution_policies()
    render(conn, :index, execution_policies: policies)
  end

  def create(conn, %{"execution_policy" => policy_params}) do
    with {:ok, %ExecutionPolicy{} = policy} <-
           ExecutionPolicies.create_execution_policy(policy_params) do
      conn
      |> put_status(:created)
      |> render(:show, execution_policy: policy)
    end
  end

  def show(conn, %{"id" => id}) do
    case ExecutionPolicies.get_execution_policy(id) do
      {:ok, policy} ->
        render(conn, :show, execution_policy: policy)

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> put_view(json: CymphoWeb.ErrorJSON)
        |> render(:"404")
    end
  end

  def update(conn, %{"id" => id, "execution_policy" => policy_params}) do
    case ExecutionPolicies.get_execution_policy(id) do
      {:ok, policy} ->
        with {:ok, %ExecutionPolicy{} = policy} <-
               ExecutionPolicies.update_execution_policy(policy, policy_params) do
          render(conn, :show, execution_policy: policy)
        end

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> put_view(json: CymphoWeb.ErrorJSON)
        |> render(:"404")
    end
  end

  def delete(conn, %{"id" => id}) do
    case ExecutionPolicies.get_execution_policy(id) do
      {:ok, policy} ->
        ExecutionPolicies.delete_execution_policy(policy)
        send_resp(conn, :no_content, "")

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> put_view(json: CymphoWeb.ErrorJSON)
        |> render(:"404")
    end
  end
end
