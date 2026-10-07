defmodule Cympho.Issues.HumanReview do
  @moduledoc false
  import Ecto.Query
  alias Cympho.{Activities, Comments, CompanyRBAC, Issues, OwnerAttention, Repo}
  alias Cympho.Comments.Comment
  alias Cympho.Issues.{ExecutionState, Issue}
  alias Cympho.Wakes.AgentWake

  @review_reasons ~w(final_review_required child_status_changed issue_children_completed)

  def decide(%Issue{} = snapshot, company_id, user_id, decision, opts)
      when decision in [:approve, :request_changes] do
    with true <- is_binary(company_id) and snapshot.company_id == company_id,
         :ok <- CompanyRBAC.authorize(user_id, company_id, :write),
         {:ok, body} <- review_body(decision, Keyword.get(opts, :reason)) do
      transaction(fn ->
        issue =
          Repo.one(
            from i in Issue,
              where: i.id == ^snapshot.id and i.company_id == ^company_id,
              lock: "FOR UPDATE"
          )

        if is_nil(issue), do: Repo.rollback(:not_found)

        if issue.status != :in_review or issue.lock_version != snapshot.lock_version,
          do: Repo.rollback(:stale_review)

        ensure_ok(CompanyRBAC.authorize(user_id, company_id, :write))
        wakes = lock_wakes(issue, decision)
        review_wakes = Enum.filter(wakes, &(&1.reason in @review_reasons))
        validate_wake(review_wakes, Keyword.get(opts, :wake_id))

        if decision == :approve do
          ensure_ok(Issues.validate_review_transition(issue, :done))

          if ExecutionState.active?(ExecutionState.normalize(issue.execution_state)),
            do: Repo.rollback(:execution_policy_not_complete)
        end

        attrs = decision_attrs(issue, decision, user_id)

        updated =
          issue
          |> Issue.changeset(attrs)
          |> Ecto.Changeset.put_change(:last_human_reviewer_id, user_id)
          |> Ecto.Changeset.optimistic_lock(:lock_version)
          |> Repo.update()
          |> ensure_ok()

        comment =
          %Comment{}
          |> Comment.changeset(%{
            issue_id: issue.id,
            author_type: "user",
            author_id: user_id,
            body: body
          })
          |> Repo.insert()
          |> ensure_ok()

        Enum.each(wakes, fn wake ->
          attrs =
            if wake.reason in @review_reasons do
              %{
                status: "consumed",
                consumed_at: DateTime.utc_now() |> DateTime.truncate(:second),
                claim_token: nil,
                claimed_at: nil
              }
            else
              %{status: "cancelled", last_error: "Issue done", claim_token: nil, claimed_at: nil}
            end

          wake
          |> AgentWake.changeset(attrs)
          |> Repo.update()
          |> ensure_ok()
        end)

        activity =
          Activities.activity_changeset(%{
            issue_id: issue.id,
            company_id: company_id,
            actor_type: "user",
            actor_id: user_id,
            action:
              if(decision == :approve,
                do: "approval_approved",
                else: "approval_requested_changes"
              ),
            metadata: %{comment_id: comment.id}
          })
          |> Repo.insert()
          |> ensure_ok()

        %{issue: issue, updated: updated, attrs: attrs, comment: comment, activity: activity}
      end)
      |> case do
        {:ok, result} ->
          Issues.publish_human_review(result.issue, result.updated, result.attrs)
          Comments.publish_comment_effects(result.comment)
          Activities.dispatch_activity(result.activity)
          OwnerAttention.notify_changed(company_id)
          {:ok, result.updated}

        {:error, reason} ->
          {:error, reason}
      end
    else
      false -> {:error, :not_found}
      error -> error
    end
  end

  def decide(_snapshot, _company_id, _user_id, _decision, _opts),
    do: {:error, :not_found}

  defp transaction(fun) do
    Repo.transaction(fun)
  rescue
    _error in [Postgrex.Error, Ecto.StaleEntryError, Ecto.ConstraintError] ->
      {:error, :persistence_failed}
  end

  defp ensure_ok(:ok), do: :ok
  defp ensure_ok({:ok, result}), do: result
  defp ensure_ok({:error, reason}), do: Repo.rollback(reason)

  defp review_body(:approve, _reason),
    do: {:ok, "[review] Verdict: approved.\nApproved and closed by the human reviewer."}

  defp review_body(:request_changes, reason) when is_binary(reason) do
    case String.trim(reason) do
      "" -> {:error, :reason_required}
      reason -> {:ok, "[review] Verdict: changes requested.\nReason: " <> reason}
    end
  end

  defp review_body(:request_changes, _reason), do: {:error, :reason_required}

  defp lock_wakes(issue, decision) do
    query =
      from w in AgentWake,
        join: a in Cympho.Agents.Agent,
        on: a.id == w.agent_id,
        where:
          w.issue_id == ^issue.id and a.company_id == ^issue.company_id and
            w.status in ["pending", "running"],
        order_by: [asc: w.id],
        lock: fragment("FOR UPDATE OF ?", w)

    query =
      if decision == :approve, do: query, else: where(query, [w], w.reason in ^@review_reasons)

    Repo.all(query)
  end

  defp validate_wake(_wakes, id) when id in [nil, ""], do: :ok

  defp validate_wake(wakes, id) do
    unless Enum.any?(wakes, &(&1.id == id)), do: Repo.rollback(:wake_not_found)
  end

  defp decision_attrs(issue, decision, user_id) do
    attrs = %{
      status: if(decision == :approve, do: :done, else: :todo),
      last_human_reviewer_id: user_id,
      actor_type: "user",
      actor_id: user_id,
      checkout_run_id: nil,
      checked_out_at: nil
    }

    if decision == :approve do
      Map.put(
        attrs,
        :completed_at,
        issue.completed_at || DateTime.utc_now() |> DateTime.truncate(:second)
      )
    else
      Map.merge(attrs, %{
        assignee_id: nil,
        assigned_role: return_role(issue.assigned_role),
        last_reviewer_id: issue.last_reviewer_id || issue.assignee_id
      })
    end
  end

  defp return_role("ceo"), do: "cto"
  defp return_role("cto"), do: "engineer"
  defp return_role(role) when is_binary(role) and role != "", do: role
  defp return_role(_role), do: "engineer"

  def error_message(:reason_required), do: "Enter a reason for requesting changes."
  def error_message(:forbidden), do: "Your company role does not allow that action."
  def error_message(:not_found), do: "Issue not found."

  def error_message(:stale_review),
    do: "This review changed. Refresh and review the latest evidence."

  def error_message(:wake_not_found), do: "This review inbox item is no longer available."
  def error_message(:blocked_by_active_issues), do: "Resolve active blockers before closing."

  def error_message(:execution_policy_not_complete),
    do: "Complete the execution policy before closing."

  def error_message({:review_gates_blocked, %{message: message}}), do: message
  def error_message(_reason), do: "Could not save this review. No decision was committed."
end
