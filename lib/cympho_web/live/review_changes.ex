defmodule CymphoWeb.Live.ReviewChanges do
  @moduledoc false
  use Phoenix.Component
  import Phoenix.LiveView, only: [put_flash: 3]
  alias Cympho.Issues
  alias Cympho.Issues.HumanReview

  def open(socket, issue_id, wake_id \\ nil) do
    with %{id: company_id} <- socket.assigns[:current_company],
         {:ok, issue} <- Issues.get_company_issue(company_id, issue_id),
         true <- issue.status == :in_review do
      {:noreply,
       assign(socket, :review_changes, %{
         issue: issue,
         wake_id: wake_id,
         reason: "",
         error: nil
       })}
    else
      _ -> {:noreply, put_flash(socket, :error, "Issue not found or no longer in review.")}
    end
  end

  def submit(socket, params, reload, message) do
    case socket.assigns[:review_changes] do
      %{issue: issue, wake_id: wake_id} = form ->
        reason = get_in(params, ["review", "reason"])

        case decide(socket, issue, :request_changes, reason: reason, wake_id: wake_id) do
          {:ok, _updated} ->
            {:noreply,
             socket |> assign(:review_changes, nil) |> put_flash(:info, message) |> reload.()}

          {:error, error} ->
            {:noreply,
             assign(socket, :review_changes, %{
               form
               | reason: if(is_binary(reason), do: reason, else: ""),
                 error: HumanReview.error_message(error)
             })}
        end

      _ ->
        {:noreply, put_flash(socket, :error, HumanReview.error_message(:stale_review))}
    end
  end

  def decide(socket, issue, decision, opts \\ []) do
    with %{id: company_id} <- socket.assigns[:current_company],
         %{id: user_id} <- socket.assigns[:current_user] do
      Issues.review_issue(issue, company_id, user_id, decision, opts)
    else
      _ -> {:error, :forbidden}
    end
  end

  attr :review_changes, :map, default: nil

  def reason_form(assigns) do
    ~H"""
    <div :if={@review_changes} class="mb-4 rounded-lg border border-border bg-panel p-4">
      <form id="review-changes-form" phx-submit="submit_review_changes">
        <p class="mb-2 text-sm font-590 text-text-primary">{@review_changes.issue.title}</p>
        <label for="review-change-reason" class="block text-sm text-text-secondary">
          Reason for requesting changes
        </label>
        <textarea
          id="review-change-reason"
          name="review[reason]"
          rows="4"
          class="mt-2 w-full rounded-lg border border-border bg-canvas text-text-primary"
          aria-describedby="review-change-error"
        >{@review_changes.reason}</textarea>
        <p
          :if={@review_changes.error}
          id="review-change-error"
          role="alert"
          class="mt-2 text-sm text-red-300"
        >
          {@review_changes.error}
        </p>
        <div class="mt-3 flex gap-2">
          <button
            type="submit"
            class="rounded-lg border border-red-500/25 bg-red-500/10 px-3 py-2 text-sm text-red-300"
          >
            Send change request
          </button>
          <button
            type="button"
            phx-click="cancel_review_changes"
            class="rounded-lg border border-border px-3 py-2 text-sm text-text-secondary"
          >
            Cancel
          </button>
        </div>
      </form>
    </div>
    """
  end
end
