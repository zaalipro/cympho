defmodule CymphoWeb.GithubController do
  use CymphoWeb, :controller
  import Ecto.Query, warn: false
  alias Cympho.{Issues, Repo}
  alias Cympho.Issues.Issue
  alias Cympho.Projects.Project
  require Logger

  @doc """
  Handles GitHub webhook events for pull requests. Verifies the
  `X-Hub-Signature-256` header against the webhook secret stored on the
  project that owns the PR. Replies 401 on missing/invalid signature, 200 on
  unknown PR or unhandled actions, 200 + side effects otherwise.
  """
  def webhook(conn, %{"action" => action, "pull_request" => pr} = _params) do
    pr_url = pr["html_url"]

    with {:ok, issue, project} <- find_issue_and_project(pr_url),
         :ok <- verify_signature(conn, project) do
      Logger.info("GitHub webhook received: action=#{action}, pr_url=#{pr_url}")
      handle_pr_action(issue, action, pr)
      send_resp(conn, :ok, "")
    else
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

  defp find_issue_and_project(pr_url) do
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

  defp handle_pr_action(issue, "closed", pr) do
    if pr["merged"] == true do
      Logger.info("PR merged for issue #{issue.id}, transitioning to done")
      Issues.transition_issue(issue, :done)
    else
      Logger.info("PR closed without merge for issue #{issue.id}, transitioning to blocked")
      Issues.transition_issue(issue, :blocked)
    end
  end

  defp handle_pr_action(issue, "synchronize", pr) do
    branch = get_in(pr, ["head", "ref"]) || "unknown"

    Cympho.Comments.create_comment(%{
      body: "PR updated on branch `#{branch}`",
      author_type: "system",
      author_id: "00000000-0000-0000-0000-000000000000",
      issue_id: issue.id
    })

    :ok
  end

  defp handle_pr_action(_issue, _action, _pr), do: :ok
end
