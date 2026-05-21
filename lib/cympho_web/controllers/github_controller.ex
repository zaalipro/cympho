defmodule CymphoWeb.GithubController do
  use CymphoWeb, :controller
  import Ecto.Query, warn: false
  alias Cympho.{Agents, Github, Issues, Repo, Wakes}
  alias Cympho.Issues.Issue
  alias Cympho.Projects.Project
  require Logger

  @doc """
  Handles GitHub webhook events. Three event families are routed:

    * `pull_request` — the existing flow: open / close / synchronize.
    * `pull_request_review` — submitted reviews (approve / changes_requested
      / commented). Each lands a `[pr-review]` comment on the linked issue
      and wakes the right agent.
    * `check_run` and `status` — CI signals. A failure wakes the assignee;
      a success-and-mergeable wakes the release engineer.

  Verifies the `X-Hub-Signature-256` header against the webhook secret
  stored on the project that owns the PR.
  """
  # `pull_request_review` delivers `{action, review, pull_request, ...}` —
  # the `review` key is the discriminator. This clause MUST come before the
  # generic pull_request clause below because review payloads also carry a
  # `pull_request` key.
  def webhook(conn, %{"action" => action, "review" => review, "pull_request" => pr} = _params) do
    pr_url = pr["html_url"]
    delivery_id = get_req_header(conn, "x-github-delivery") |> List.first()

    with {:ok, issue, project} <- find_issue_and_project(pr_url, pr),
         :ok <- verify_signature(conn, project),
         :fresh <- Cympho.WebhookDedup.check_and_mark(delivery_id) do
      Logger.info("GitHub review webhook: action=#{action}, pr_url=#{pr_url}")
      handle_review_action(issue, action, review, pr)
      send_resp(conn, :ok, "")
    else
      :duplicate -> send_resp(conn, :ok, "")
      {:error, :not_found} -> send_resp(conn, :ok, "")
      {:error, :no_project} -> send_resp(conn, :unauthorized, "")
      {:error, :no_secret} -> send_resp(conn, :unauthorized, "")
      {:error, :invalid_signature} -> send_resp(conn, :unauthorized, "")
    end
  end

  # `check_run` events fire on CI run completion. We care about
  # `action == "completed"` with a `conclusion`. Failures wake the
  # assignee; successes are recorded in monitor_state and (when the PR
  # is otherwise green and approved) wake the release engineer.
  def webhook(conn, %{"action" => "completed", "check_run" => check_run} = _params) do
    pr_url = check_run_pr_url(check_run)
    delivery_id = get_req_header(conn, "x-github-delivery") |> List.first()

    if is_nil(pr_url) do
      send_resp(conn, :ok, "")
    else
      with {:ok, issue, project} <- find_issue_and_project(pr_url),
           :ok <- verify_signature(conn, project),
           :fresh <- Cympho.WebhookDedup.check_and_mark(delivery_id) do
        handle_check_run(issue, check_run)
        send_resp(conn, :ok, "")
      else
        :duplicate -> send_resp(conn, :ok, "")
        {:error, :not_found} -> send_resp(conn, :ok, "")
        {:error, :no_project} -> send_resp(conn, :unauthorized, "")
        {:error, :no_secret} -> send_resp(conn, :unauthorized, "")
        {:error, :invalid_signature} -> send_resp(conn, :unauthorized, "")
      end
    end
  end

  # Generic `pull_request` event (no `review` key — already handled above).
  # This is the original opened/closed/synchronize handler.
  def webhook(conn, %{"action" => action, "pull_request" => pr} = _params) do
    pr_url = pr["html_url"]
    delivery_id = get_req_header(conn, "x-github-delivery") |> List.first()

    with {:ok, issue, project} <- find_issue_and_project(pr_url, pr),
         :ok <- verify_signature(conn, project),
         :fresh <- Cympho.WebhookDedup.check_and_mark(delivery_id) do
      Logger.info("GitHub webhook received: action=#{action}, pr_url=#{pr_url}")
      issue = record_pr_quality_from_webhook(issue, action, pr)
      handle_pr_action(issue, action, pr)
      send_resp(conn, :ok, "")
    else
      :duplicate ->
        Logger.info("GitHub webhook duplicate delivery: id=#{delivery_id}, pr_url=#{pr_url}")
        send_resp(conn, :ok, "")

      {:error, :not_found} ->
        Logger.info("No issue found linked to PR: #{pr_url}")
        send_resp(conn, :ok, "")

      {:error, :no_project} ->
        Logger.warning("Issue linked to PR has no project; refusing: #{pr_url}")
        send_resp(conn, :unauthorized, "")

      {:error, :no_secret} ->
        Logger.warning("Project missing github_webhook_secret; refusing: #{pr_url}")
        send_resp(conn, :unauthorized, "")

      {:error, :invalid_signature} ->
        send_resp(conn, :unauthorized, "")
    end
  end

  def webhook(conn, _params) do
    send_resp(conn, :ok, "")
  end

  defp find_issue_and_project(pr_url, pr \\ nil) do
    case find_by_pr_url(pr_url) do
      {:ok, _issue, _project} = ok ->
        ok

      {:error, :no_project} = err ->
        err

      {:error, :not_found} ->
        try_auto_link_by_branch(pr_url, pr)
    end
  end

  defp find_by_pr_url(pr_url) do
    query =
      from i in Issue,
        where: i.github_pr_url == ^pr_url,
        preload: [:project]

    case Repo.all(query) do
      [%Issue{project: %Project{} = project} = issue] -> {:ok, issue, project}
      [%Issue{project: nil}] -> {:error, :no_project}
      [] -> {:error, :not_found}
    end
  end

  # When the URL lookup misses, fall back to the branch convention encoded in
  # `PullRequestContract.branch_name(issue)` — `<identifier>/<slug>`. We
  # match the project first (via `repo_url`) so the identifier lookup is
  # unambiguous, then auto-link the PR URL onto the issue so subsequent
  # webhooks find it by URL directly.
  defp try_auto_link_by_branch(_pr_url, nil), do: {:error, :not_found}

  defp try_auto_link_by_branch(pr_url, pr) do
    with {:ok, branch} <- extract_branch_ref(pr),
         {:ok, identifier} <- extract_branch_identifier(branch),
         {:ok, project} <- find_project_by_pr(pr),
         {:ok, issue} <- Issues.get_by_identifier(identifier, project_id: project.id),
         {:ok, linked} <- attach_pr_to_issue(issue, pr_url, branch) do
      Logger.info(
        "Auto-linked PR by branch convention: branch=#{branch} identifier=#{identifier} issue=#{linked.id} pr_url=#{pr_url}"
      )

      {:ok, linked, project}
    else
      _ -> {:error, :not_found}
    end
  end

  defp extract_branch_ref(pr) do
    case get_in(pr, ["head", "ref"]) do
      ref when is_binary(ref) and ref != "" -> {:ok, ref}
      _ -> :error
    end
  end

  defp extract_branch_identifier(branch) do
    case String.split(branch, "/", parts: 2) do
      [identifier, _slug] when identifier != "" -> {:ok, identifier}
      _ -> :error
    end
  end

  defp find_project_by_pr(pr) do
    candidates =
      [
        get_in(pr, ["base", "repo", "html_url"]),
        get_in(pr, ["head", "repo", "html_url"])
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&String.trim_trailing(&1, "/"))
      |> Enum.uniq()

    case candidates do
      [] ->
        :error

      urls ->
        case Repo.all(from p in Project, where: p.repo_url in ^urls, limit: 2) do
          [%Project{} = project] -> {:ok, project}
          _ -> :error
        end
    end
  end

  defp attach_pr_to_issue(%Issue{github_pr_url: existing} = issue, pr_url, _branch)
       when is_binary(existing) and existing != "" and existing != pr_url do
    # A different PR is already linked. Refuse to silently steal the slot.
    Logger.warning(
      "Refused branch auto-link: issue #{issue.id} already linked to #{existing}, would not overwrite with #{pr_url}"
    )

    :error
  end

  defp attach_pr_to_issue(%Issue{} = issue, pr_url, branch) do
    case Issues.update_issue(issue, %{github_pr_url: pr_url}) do
      {:ok, updated} ->
        _ =
          Cympho.Comments.create_comment(%{
            body:
              "[auto-link] Linked PR to this issue via branch convention `#{branch}` → #{pr_url}",
            author_type: "system",
            author_id: "00000000-0000-0000-0000-000000000000",
            issue_id: updated.id
          })

        {:ok, Repo.preload(updated, :project)}

      {:error, reason} ->
        Logger.warning(
          "Auto-link update failed for issue #{issue.id}: #{inspect(reason)}"
        )

        :error
    end
  end

  defp verify_signature(conn, %Project{github_webhook_secret: secret})
       when is_binary(secret) and byte_size(secret) > 0 do
    signature =
      conn.assigns[:github_webhook_signature] ||
        get_req_header(conn, "x-hub-signature-256") |> List.first()

    raw_body = raw_body(conn)

    case signature do
      "sha256=" <> hex when is_binary(hex) and is_binary(raw_body) ->
        expected = :crypto.mac(:hmac, :sha256, secret, raw_body) |> Base.encode16(case: :lower)

        if Plug.Crypto.secure_compare(expected, String.downcase(hex)) do
          :ok
        else
          {:error, :invalid_signature}
        end

      _ ->
        {:error, :invalid_signature}
    end
  end

  defp verify_signature(_conn, _project), do: {:error, :no_secret}

  defp raw_body(conn) do
    case conn.assigns[:raw_body] do
      chunks when is_list(chunks) -> chunks |> Enum.reverse() |> IO.iodata_to_binary()
      _ -> nil
    end
  end

  defp record_pr_quality_from_webhook(issue, action, pr) do
    metadata = Github.pull_request_metadata(pr)

    case Issues.record_pr_quality_from_metadata(issue, metadata,
           source: "github_webhook:#{action}"
         ) do
      {:ok, updated, _pr_quality} ->
        updated

      {:error, reason} ->
        Logger.warning(
          "Failed to record PR quality from webhook for issue #{issue.id}: #{inspect(reason)}"
        )

        issue
    end
  end

  defp handle_pr_action(issue, "opened", _pr) do
    cond do
      issue.status == :backlog ->
        with {:ok, in_progress} <- Issues.transition_issue(issue, :in_progress) do
          Issues.transition_issue(in_progress, :in_review)
        end

      issue.status == :todo ->
        with {:ok, in_progress} <- Issues.transition_issue(issue, :in_progress) do
          Issues.transition_issue(in_progress, :in_review)
        end

      issue.status == :in_progress ->
        Issues.transition_issue(issue, :in_review)

      true ->
        :ok
    end
  end

  # Merging a PR no longer auto-closes the issue. Promote to :in_review and
  # wake the company CEO for terminal sign-off — this preserves the
  # `ensure_approval_quality` gate that auto-:done was bypassing. The CEO
  # then `approve_issue` (or `request_changes`) to actually close the work.
  defp handle_pr_action(issue, "closed", pr) do
    if pr["merged"] == true do
      Logger.info("PR merged for issue #{issue.id}, promoting to :in_review for CEO sign-off")

      _ =
        Cympho.Comments.create_comment(%{
          body: "[review] PR merged. Awaiting CEO sign-off before this issue closes.",
          author_type: "system",
          author_id: "00000000-0000-0000-0000-000000000000",
          issue_id: issue.id
        })

      with {:ok, transitioned} <- Issues.transition_issue(issue, :in_review) do
        # Direct fire of final-review wake; falls back to company CEO when
        # the issue has no current assignee.
        wake_for_final_review(transitioned)
        {:ok, transitioned}
      end
    else
      Logger.info("PR closed without merge for issue #{issue.id}, transitioning to blocked")
      Issues.transition_issue(issue, :blocked)
    end
  end

  # `synchronize` means a new commit was pushed. Inspect mergeable; if false
  # wake whoever owns the issue with a `merge_conflict_detected` reason so
  # the engineer (or release engineer on fallback) rebases.
  defp handle_pr_action(issue, "synchronize", pr) do
    branch = get_in(pr, ["head", "ref"]) || "unknown"

    Cympho.Comments.create_comment(%{
      body: "PR updated on branch `#{branch}`",
      author_type: "system",
      author_id: "00000000-0000-0000-0000-000000000000",
      issue_id: issue.id
    })

    if pr["mergeable"] == false do
      target_id = pick_conflict_resolver(issue)

      if is_binary(target_id) do
        Wakes.wake_for_merge_conflict(target_id, issue.id, %{
          "pr_url" => pr["html_url"],
          "head_sha" => get_in(pr, ["head", "sha"]),
          "base_branch" => get_in(pr, ["base", "ref"])
        })
      end
    end

    :ok
  end

  defp handle_pr_action(_issue, _action, _pr), do: :ok

  ## review handlers

  # `submitted` reviews are the primary signal. We post a `[pr-review]`
  # comment with the review body so the issue stream has the audit trail,
  # then wake based on review state.
  defp handle_review_action(issue, "submitted", review, _pr) do
    state = review["state"] || "commented"
    body = review["body"] || ""
    reviewer = get_in(review, ["user", "login"]) || "external reviewer"

    tag =
      case state do
        "approved" -> "[pr-review] APPROVED"
        "changes_requested" -> "[pr-review] CHANGES REQUESTED"
        _ -> "[pr-review] COMMENTED"
      end

    _ =
      Cympho.Comments.create_comment(%{
        body: "#{tag} by #{reviewer}\n\n#{body}",
        author_type: "system",
        author_id: "00000000-0000-0000-0000-000000000000",
        issue_id: issue.id
      })

    metadata = %{
      "review_id" => review["id"],
      "reviewer" => reviewer,
      "review_state" => state,
      "review_url" => review["html_url"]
    }

    case state do
      "changes_requested" ->
        # Bring the issue back to :in_progress and ping the original
        # delivery agent. The agent's prompt will surface the new
        # [pr-review] comment in their context.
        with assignee_id when is_binary(assignee_id) <- issue.assignee_id do
          _ = Issues.transition_issue(issue, :in_progress)

          Wakes.wake_for_pr_review_changes_requested(
            assignee_id,
            issue.id,
            metadata
          )
        end

      "approved" ->
        # Approved reviews don't transition anything by themselves —
        # CI + mergeable + a `merge_pr` action close the loop. But we wake
        # the release engineer (if one exists) so they can run the merge.
        target_id = pick_release_engineer(issue) || issue.assignee_id

        if is_binary(target_id) do
          Wakes.wake_for_pr_ready_to_merge(
            target_id,
            issue.id,
            Map.put(metadata, "approved", true)
          )
        end

      _ ->
        # plain "commented" review — just nudge the assignee.
        if is_binary(issue.assignee_id) do
          Wakes.wake_for_pr_review_commented(issue.assignee_id, issue.id, metadata)
        end
    end

    :ok
  end

  defp handle_review_action(_issue, _action, _review, _pr), do: :ok

  ## check_run handlers

  defp handle_check_run(issue, %{"conclusion" => "failure"} = check_run) do
    metadata = %{
      "check_run_url" => check_run["html_url"],
      "name" => check_run["name"],
      "conclusion" => "failure"
    }

    if is_binary(issue.assignee_id) do
      Wakes.wake_for_ci_failed(issue.assignee_id, issue.id, metadata)
    end

    _ =
      Cympho.Comments.create_comment(%{
        body: "[ci] FAILED — #{check_run["name"] || "build"} (#{check_run["html_url"]})",
        author_type: "system",
        author_id: "00000000-0000-0000-0000-000000000000",
        issue_id: issue.id
      })

    :ok
  end

  defp handle_check_run(_issue, _check_run), do: :ok

  defp check_run_pr_url(%{"pull_requests" => [%{} = pr | _]}) do
    cond do
      is_binary(pr["html_url"]) -> pr["html_url"]
      is_binary(pr["url"]) -> pr["url"]
      true -> nil
    end
  end

  defp check_run_pr_url(_), do: nil

  ## supervisor / role pickers

  # On merge conflict: prefer a release engineer, fall back to the issue
  # assignee, fall back to the company CEO.
  defp pick_conflict_resolver(%Issue{} = issue) do
    pick_release_engineer(issue) || issue.assignee_id || pick_company_ceo(issue.company_id)
  end

  defp pick_release_engineer(%Issue{company_id: nil}), do: nil

  defp pick_release_engineer(%Issue{company_id: company_id}) do
    case Agents.list_eligible_agents(:release_engineer, company_id) do
      [%{id: id} | _] -> id
      _ -> nil
    end
  end

  defp pick_company_ceo(nil), do: nil

  defp pick_company_ceo(company_id) do
    case Agents.get_company_ceo(company_id) do
      {:ok, %{id: id}} -> id
      _ -> nil
    end
  end

  ## final review wake (used after merge auto-:in_review)

  defp wake_for_final_review(%Issue{assignee_id: assignee_id, id: issue_id, company_id: company_id}) do
    target =
      cond do
        is_binary(assignee_id) -> assignee_id
        is_binary(company_id) -> pick_company_ceo(company_id)
        true -> nil
      end

    if is_binary(target) do
      Cympho.Wakes.do_wake_agent(
        target,
        issue_id,
        "final_review_required",
        "system",
        nil,
        %{"source" => "github_merged"}
      )
    end

    :ok
  end
end
