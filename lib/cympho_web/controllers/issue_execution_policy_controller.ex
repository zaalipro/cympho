defmodule CymphoWeb.IssueExecutionPolicyController do
  use CymphoWeb, :controller

  alias Cympho.Issues

  action_fallback CymphoWeb.FallbackController

  def assign(conn, %{
        "issue_id" => issue_id,
        "execution_policy_id" => policy_id,
        "executor_id" => executor_id
      }) do
    with {:ok, issue} <- scoped_issue(conn, issue_id),
         {:ok, updated} <- Issues.assign_execution_policy(issue, policy_id, executor_id) do
      conn
      |> put_status(:ok)
      |> json(%{
        id: updated.id,
        execution_policy_id: updated.execution_policy_id,
        execution_state: updated.execution_state
      })
    end
  end

  def decide(conn, %{"issue_id" => issue_id, "decision" => decision} = params)
      when decision in ["approve", "request_changes"] do
    atom_decision = String.to_existing_atom(decision)
    decided_by = params["decided_by"] || conn.assigns.current_user.id

    with {:ok, issue} <- scoped_issue(conn, issue_id),
         {:ok, updated} <- Issues.execution_policy_decision(issue, atom_decision, decided_by) do
      conn
      |> put_status(:ok)
      |> json(%{
        id: updated.id,
        status: to_string(updated.status),
        execution_state: updated.execution_state
      })
    end
  end

  defp scoped_issue(conn, issue_id) do
    Issues.get_company_issue(conn.assigns.current_company.id, issue_id)
  end
end
