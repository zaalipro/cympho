defmodule CymphoWeb.GithubController do
  use CymphoWeb, :controller
  import Ecto.Query, warn: false
  alias Cympho.Issues
  require Logger

  @doc """
  Handles GitHub webhook events for pull requests.

  Expected payload structure for pull_request events:
  %{
    "action" => "opened" | "closed" | "synchronize" | ...,
    "pull_request" => %{
      "html_url" => "https://github.com/owner/repo/pull/123",
      "merged" => boolean,
      "title" => "PR Title"
    },
    "repository" => %{
      "full_name" => "owner/repo"
    }
  }
  """
  def webhook(conn, %{"action" => action, "pull_request" => pr} = _params) do
    Logger.info("GitHub webhook received: action=#{action}, pr_url=#{pr["html_url"]}")

    pr_url = pr["html_url"]

    case find_issue_by_pr_url(pr_url) do
      {:ok, issue} ->
        handle_pr_action(issue, action, pr)
        send_resp(conn, :ok, "")

      {:error, :not_found} ->
        Logger.info("No issue found linked to PR: #{pr_url}")
        send_resp(conn, :ok, "")
    end
  end

  def webhook(conn, _params) do
    send_resp(conn, :ok, "")
  end

  defp find_issue_by_pr_url(pr_url) do
    query = from(i in Cympho.Issues.Issue, where: i.github_pr_url == ^pr_url)

    case Cympho.Repo.all(query) do
      [issue] -> {:ok, issue}
      [] -> {:error, :not_found}
    end
  end

  defp handle_pr_action(issue, "opened", _pr) do
    if issue.status in [:todo, :in_progress] do
      Logger.info("PR opened for issue #{issue.id}, transitioning to in_review")
      Issues.transition_issue(issue, :in_review)
    end
  end

  defp handle_pr_action(issue, "closed", pr) do
    if pr["merged"] == true do
      Logger.info("PR merged for issue #{issue.id}, transitioning to done")
      Issues.transition_issue(issue, :done)
    else
      Logger.info("PR closed without merge for issue #{issue.id}, transitioning to blocked")
      Issues.transition_issue(issue, :blocked)
    end
  end

  defp handle_pr_action(_issue, _action, _pr), do: :ok
end
