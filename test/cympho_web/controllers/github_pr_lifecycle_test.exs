defmodule CymphoWeb.GithubPrLifecycleTest do
  use CymphoWeb.ConnCase, async: false

  alias Cympho.{Agents, Companies, Issues, Repo}
  alias Cympho.Wakes.AgentWake
  import Ecto.Query

  setup do
    {:ok,
     %{
       company: company,
       agents: [_ceo, _cto, engineer | _],
       seed_issues: [seed | _]
     }} =
      Companies.create_autonomous_company(%{
        name: "PR Lifecycle Co #{System.unique_integer([:positive])}",
        issue_prefix: "PRL",
        engineer_count: 1
      })

    {:ok, project} = Cympho.Projects.create_project(%{
      name: "PRL Project",
      prefix: "PRLX",
      company_id: company.id,
      github_webhook_secret: "lifecycle-test-secret"
    })

    {:ok, issue} =
      Issues.update_issue(seed, %{
        project_id: project.id,
        assignee_id: engineer.id,
        status: :in_review,
        github_pr_url: "https://github.com/owner/repo/pull/777"
      })

    %{
      company: company,
      project: project,
      engineer: engineer,
      issue: issue
    }
  end

  describe "pull_request_review webhook" do
    test "changes_requested → comment + transition + wake on assignee", %{
      conn: conn,
      project: project,
      issue: issue,
      engineer: engineer
    } do
      payload =
        review_payload("submitted", "changes_requested",
          pr_url: issue.github_pr_url,
          body: "Please fix the null check on line 42"
        )

      conn = post_signed_webhook(conn, payload, project.github_webhook_secret)
      assert response(conn, :ok) == ""

      reloaded = Issues.get_issue!(issue.id)
      assert reloaded.status == :in_progress

      [wake] = pending_wakes(engineer.id, "pr_review_changes_requested")
      assert wake.metadata["review_state"] == "changes_requested"

      assert Repo.exists?(
               from c in Cympho.Comments.Comment,
                 where:
                   c.issue_id == ^issue.id and
                     fragment("? LIKE ?", c.body, "[pr-review] CHANGES REQUESTED%")
             )
    end

    test "approved → wake release engineer if one exists", %{
      conn: conn,
      project: project,
      company: company,
      issue: issue
    } do
      {:ok, release_eng} =
        Agents.create_agent(%{
          name: "Release Eng",
          role: :release_engineer,
          status: :idle,
          company_id: company.id
        })

      payload = review_payload("submitted", "approved", pr_url: issue.github_pr_url)
      conn = post_signed_webhook(conn, payload, project.github_webhook_secret)
      assert response(conn, :ok) == ""

      [wake] = pending_wakes(release_eng.id, "pr_ready_to_merge")
      assert wake.metadata["approved"] == true
    end

    test "approved without release engineer → wake assignee", %{
      conn: conn,
      project: project,
      issue: issue,
      engineer: engineer
    } do
      payload = review_payload("submitted", "approved", pr_url: issue.github_pr_url)
      conn = post_signed_webhook(conn, payload, project.github_webhook_secret)
      assert response(conn, :ok) == ""

      assert pending_wakes(engineer.id, "pr_ready_to_merge") |> length() == 1
    end

    test "commented (non-blocking) → comment + wake_for_pr_review_commented",
         %{
           conn: conn,
           project: project,
           issue: issue,
           engineer: engineer
         } do
      payload = review_payload("submitted", "commented", pr_url: issue.github_pr_url, body: "nit on style")
      conn = post_signed_webhook(conn, payload, project.github_webhook_secret)
      assert response(conn, :ok) == ""

      assert pending_wakes(engineer.id, "pr_review_commented") |> length() == 1
    end
  end

  describe "synchronize webhook with merge conflict" do
    test "mergeable=false fires merge_conflict_detected wake on release engineer fallback",
         %{
           conn: conn,
           project: project,
           company: company,
           issue: issue
         } do
      {:ok, release_eng} =
        Agents.create_agent(%{
          name: "Release Eng",
          role: :release_engineer,
          status: :idle,
          company_id: company.id
        })

      payload =
        pr_payload("synchronize", issue.github_pr_url,
          mergeable: false,
          base_ref: "main",
          head_sha: "abc123"
        )

      conn = post_signed_webhook(conn, payload, project.github_webhook_secret)
      assert response(conn, :ok) == ""

      [wake] = pending_wakes(release_eng.id, "merge_conflict_detected")
      assert wake.metadata["base_branch"] == "main"
      assert wake.metadata["head_sha"] == "abc123"
    end
  end

  describe "check_run webhook" do
    test "failure conclusion fires ci_failed wake on assignee + adds [ci] FAILED comment", %{
      conn: conn,
      project: project,
      issue: issue,
      engineer: engineer
    } do
      payload = check_run_payload("completed", "failure", pr_url: issue.github_pr_url)
      conn = post_signed_webhook(conn, payload, project.github_webhook_secret)
      assert response(conn, :ok) == ""

      assert pending_wakes(engineer.id, "ci_failed") |> length() == 1

      assert Repo.exists?(
               from c in Cympho.Comments.Comment,
                 where:
                   c.issue_id == ^issue.id and
                     fragment("? LIKE ?", c.body, "[ci] FAILED%")
             )
    end
  end

  ## payload + helper builders

  defp review_payload(action, state, opts) do
    pr_url = Keyword.fetch!(opts, :pr_url)
    body = Keyword.get(opts, :body, "")

    %{
      "action" => action,
      "review" => %{
        "id" => 9_876,
        "body" => body,
        "state" => state,
        "html_url" => "#{pr_url}/reviews/9876",
        "user" => %{"login" => "external-reviewer"}
      },
      "pull_request" => %{
        "html_url" => pr_url,
        "title" => "PR title",
        "head" => %{"ref" => "feature"}
      },
      "repository" => %{"full_name" => "owner/repo"}
    }
  end

  defp pr_payload(action, pr_url, opts) do
    %{
      "action" => action,
      "pull_request" => %{
        "html_url" => pr_url,
        "title" => "PR title",
        "merged" => false,
        "mergeable" => Keyword.get(opts, :mergeable, true),
        "head" => %{
          "ref" => "feature",
          "sha" => Keyword.get(opts, :head_sha, "deadbeef")
        },
        "base" => %{"ref" => Keyword.get(opts, :base_ref, "main")}
      },
      "repository" => %{"full_name" => "owner/repo"}
    }
  end

  defp check_run_payload(action, conclusion, opts) do
    pr_url = Keyword.fetch!(opts, :pr_url)

    %{
      "action" => action,
      "check_run" => %{
        "name" => "tests",
        "html_url" => "#{pr_url}/checks/123",
        "conclusion" => conclusion,
        "pull_requests" => [%{"html_url" => pr_url}]
      }
    }
  end

  defp post_signed_webhook(conn, payload, secret) do
    payload_json = Jason.encode!(payload)
    signature = compute_signature(payload, secret)

    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-hub-signature-256", signature)
    |> put_req_header("x-github-delivery", "test-#{System.unique_integer([:positive])}")
    |> post("/api/github/webhook", payload_json)
  end

  defp compute_signature(payload, secret) do
    payload_json = Jason.encode!(payload)

    :crypto.mac(:hmac, :sha256, secret, payload_json)
    |> Base.encode16(case: :lower)
    |> then(&"sha256=#{&1}")
  end

  defp pending_wakes(agent_id, reason) do
    Repo.all(
      from w in AgentWake,
        where: w.agent_id == ^agent_id and w.reason == ^reason and w.status == "pending"
    )
  end
end
