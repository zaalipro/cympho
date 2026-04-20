defmodule CymphoWeb.GithubController do
  use CymphoWeb, :controller

  import Ecto.Query

  alias Cympho.Issues
  alias Cympho.Comments
  alias Cympho.GithubWebhook
  require Logger

  @doc """
  Handles GitHub webhook events for pull requests.

  Expected payload structure for pull_request events:
  %{
    "action" => "opened" | "closed" | "synchronize" | ...,
    "pull_request" => %{
      "html_url" => "https://github.com/owner/repo/pull/123",
      "merged" => boolean,
      "title" => "PR Title",
      "head" => %{"ref" => "branch-name"}
    },
    "repository" => %{
      "full_name" => "owner/repo"
    }
  }
  """
  def webhook(conn, %{"action" => action, "pull_request" => pr} = params) do
    pr_url = pr["html_url"]

    case find_issue_by_pr_url(pr_url) do
      {:ok, issue} ->
        project = issue.project

        with :ok <- verify_signature(conn, project),
             :ok <- handle_pr_action(issue, action, pr) do
          send_resp(conn, :ok, "")
        else
          {:error, :unauthorized} ->
            Logger.warning("GitHub webhook unauthorized for PR: #{pr_url}")
            send_resp(conn, :unauthorized, "")
        end

      {:error, :not_found} ->
        Logger.info("No issue found linked to PR: #{pr_url}")
        send_resp(conn, :ok, "")
    end
  end

  def webhook(conn, _params) do
    send_resp(conn, :ok, "")
  end

  defp verify_signature(conn, project) do
    signature = conn.assigns[:github_webhook_signature]
    raw_body = conn.assigns[:github_webhook_raw_body]
    secret = project && project.github_webhook_secret

    GithubWebhook.verify_signature(raw_body, signature, secret)
  end

  defp find_issue_by_pr_url(pr_url) do
    case Cympho.Repo.all(from i in Cympho.Issues.Issue, where: i.github_pr_url == ^pr_url, preload: [:project]) do
      [issue] -> {:ok, issue}
      [] -> {:error, :not_found}
    end
  end

  defp handle_pr_action(issue, "opened", _pr) do
    Logger.info("PR opened for issue #{issue.id}, transitioning to in_review")
    Issues.transition_issue(issue, :in_review)
    :ok
  end

  defp handle_pr_action(issue, "synchronize", pr) do
    branch = pr["head"]["ref"]
    Logger.info("PR updated (synchronize) for issue #{issue.id}, branch: #{branch}")
    add_system_comment(issue, "PR updated: #{branch}")
    :ok
  end

  defp handle_pr_action(issue, "closed", pr) do
    if pr["merged"] == true do
      Logger.info("PR merged for issue #{issue.id}, transitioning to done")
      Issues.transition_issue(issue, :done)
    else
      Logger.info("PR closed without merge for issue #{issue.id}, transitioning to blocked")
      Issues.transition_issue(issue, :blocked)
      add_system_comment(issue, "PR closed without merge")
    end
    :ok
  end

  defp handle_pr_action(_issue, _action, _pr), do: :ok

  defp add_system_comment(%Cympho.Issues.Issue{} = issue, body) do
    Comments.create_comment(%{
      body: body,
      author_type: "system",
      author_id: "00000000-0000-0000-0000-000000000000",
      issue_id: issue.id
    })
  end
end