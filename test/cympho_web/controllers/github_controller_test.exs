defmodule CymphoWeb.GithubControllerTest do
  use CymphoWeb.ConnCase, async: true

  alias Cympho.Issues
  alias Cympho.Projects
  alias Cympho.Agents
  alias Cympho.PullRequestContract
  alias Cympho.ReviewNudges
  alias Cympho.Wakes

  setup do
    # Create a project with a webhook secret
    {:ok, project} =
      Projects.create_project(%{
        name: "Test Project",
        prefix: "TEST",
        github_webhook_secret: "test-webhook-secret"
      })

    # Create an agent to act as the creator
    {:ok, agent} =
      Agents.create_agent(%{
        name: "Test Agent",
        role: :engineer,
        status: :idle
      })

    # Create an issue with a GitHub PR URL linked
    {:ok, issue} =
      Issues.create_issue(%{
        title: "GitHub Linked Issue",
        description: "Issue with PR linked",
        status: :in_progress,
        priority: :high,
        project_id: project.id,
        github_pr_url: "https://github.com/owner/repo/pull/123"
      })

    %{project: project, agent: agent, issue: issue}
  end

  describe "webhook authentication" do
    test "returns 401 when signature is missing", %{conn: conn, issue: issue} do
      payload = build_pr_payload("opened", issue.github_pr_url)

      conn =
        conn
        |> put_req_header("x-hub-signature-256", "")
        |> post("/api/github/webhook", payload)

      assert response(conn, :unauthorized) == ""
    end

    test "returns 401 when signature is invalid", %{conn: conn, issue: issue, project: _project} do
      payload = build_pr_payload("opened", issue.github_pr_url)

      conn =
        conn
        |> put_req_header("x-hub-signature-256", "sha256=invalidsignature")
        |> post("/api/github/webhook", payload)

      assert response(conn, :unauthorized) == ""
    end
  end

  describe "webhook PR actions" do
    test "PR opened transitions issue to in_review", %{conn: conn, issue: issue, project: project} do
      payload = build_pr_payload("opened", issue.github_pr_url)
      conn = post_signed_webhook(conn, payload, project.github_webhook_secret)

      assert response(conn, :ok) == ""

      # Verify issue was transitioned to in_review
      updated_issue = Issues.get_issue!(issue.id)
      assert updated_issue.status == :in_review
    end

    test "PR opened for issue in backlog transitions backlog -> in_progress -> in_review", %{
      conn: conn,
      project: project
    } do
      {:ok, backlog_issue} =
        Issues.create_issue(%{
          title: "Backlog Issue",
          description: "Issue in backlog",
          status: :backlog,
          priority: :medium,
          project_id: project.id,
          github_pr_url: "https://github.com/owner/repo/pull/124"
        })

      payload = build_pr_payload("opened", backlog_issue.github_pr_url)
      conn = post_signed_webhook(conn, payload, project.github_webhook_secret)

      assert response(conn, :ok) == ""

      # Verify issue was transitioned through in_progress to in_review
      updated_issue = Issues.get_issue!(backlog_issue.id)
      assert updated_issue.status == :in_review
    end

    test "PR opened for issue in todo transitions todo -> in_progress -> in_review", %{
      conn: conn,
      project: project
    } do
      {:ok, todo_issue} =
        Issues.create_issue(%{
          title: "Todo Issue",
          description: "Issue in todo",
          status: :todo,
          priority: :medium,
          project_id: project.id,
          github_pr_url: "https://github.com/owner/repo/pull/125"
        })

      payload = build_pr_payload("opened", todo_issue.github_pr_url)
      conn = post_signed_webhook(conn, payload, project.github_webhook_secret)

      assert response(conn, :ok) == ""

      # Verify issue was transitioned through in_progress to in_review
      updated_issue = Issues.get_issue!(todo_issue.id)
      assert updated_issue.status == :in_review
    end

    test "PR synchronize adds a system comment", %{conn: conn, issue: issue, project: project} do
      payload =
        build_pr_payload("synchronize", issue.github_pr_url, %{
          "head" => %{"ref" => "feature-branch"}
        })

      conn = post_signed_webhook(conn, payload, project.github_webhook_secret)

      assert response(conn, :ok) == ""

      # Verify a system comment was added
      updated_issue = Issues.get_issue!(issue.id)
      assert length(updated_issue.comments) > 0
    end

    test "PR synchronize refreshes quality state and clears queued PR nudges", %{
      conn: conn,
      issue: issue,
      agent: agent,
      project: project
    } do
      {:ok, issue} =
        Issues.update_issue(issue, %{
          assignee_id: agent.id,
          monitor_state: %{
            "pr_quality" => %{
              "status" => "attention",
              "summary" => "1 PR contract gap needs fixes.",
              "gaps" => [
                %{"label" => "Task List checkboxes", "detail" => "Task List needs checkboxes."}
              ]
            }
          }
        })

      assert {:ok, _queued} =
               ReviewNudges.execute_contract_gap(issue, "pr_quality", agents: [agent])

      assert [_pending] = Wakes.list_review_nudges([issue.id])

      payload =
        build_pr_payload("synchronize", issue.github_pr_url, %{
          "title" => PullRequestContract.title(issue),
          "body" => PullRequestContract.body_template(issue),
          "head" => %{"ref" => PullRequestContract.branch_name(issue)},
          "number" => 123,
          "state" => "open"
        })

      conn = post_signed_webhook(conn, payload, project.github_webhook_secret)

      assert response(conn, :ok) == ""

      updated_issue = Issues.get_issue!(issue.id)
      assert updated_issue.monitor_state["pr_quality"]["status"] == "ready"
      assert updated_issue.monitor_state["pr_quality"]["passed"] == true

      assert updated_issue.monitor_state["pr_quality"]["checked_source"] ==
               "github_webhook:synchronize"

      assert updated_issue.monitor_state["pr_quality"]["missing_fields"] == []

      assert [] = Wakes.list_review_nudges([issue.id])
      assert [_cleared] = Wakes.list_review_nudges([issue.id], statuses: ["consumed"])
    end

    test "duplicate delivery (same X-GitHub-Delivery) is short-circuited and runs side effects only once",
         %{conn: conn, issue: issue, project: project} do
      payload =
        build_pr_payload("synchronize", issue.github_pr_url, %{
          "head" => %{"ref" => "feature-branch"}
        })

      delivery_id = "delivery-" <> Integer.to_string(System.unique_integer([:positive]))

      conn1 =
        post_signed_webhook_with_delivery(
          conn,
          payload,
          project.github_webhook_secret,
          delivery_id
        )

      assert response(conn1, :ok) == ""
      first_count = length(Issues.get_issue!(issue.id).comments)

      # Re-deliver the exact same payload + delivery id; the controller must
      # ack with 200 but skip the side effect.
      conn2 =
        post_signed_webhook_with_delivery(
          build_conn(),
          payload,
          project.github_webhook_secret,
          delivery_id
        )

      assert response(conn2, :ok) == ""
      assert length(Issues.get_issue!(issue.id).comments) == first_count
    end

    test "PR merged transitions issue to :in_review for CEO sign-off (not :done)", %{
      conn: conn,
      issue: issue,
      project: project
    } do
      payload = build_pr_payload("closed", issue.github_pr_url, %{"merged" => true})
      conn = post_signed_webhook(conn, payload, project.github_webhook_secret)

      assert response(conn, :ok) == ""

      # New behavior: merged PRs go to :in_review, not :done. The CEO must
      # explicitly emit `approve_issue` to close the work — this preserves
      # the ensure_approval_quality gate that the auto-:done path bypassed.
      updated_issue = Issues.get_issue!(issue.id)
      assert updated_issue.status == :in_review
    end

    test "PR closed without merge transitions issue to blocked", %{
      conn: conn,
      issue: issue,
      project: project
    } do
      payload = build_pr_payload("closed", issue.github_pr_url, %{"merged" => false})
      conn = post_signed_webhook(conn, payload, project.github_webhook_secret)

      assert response(conn, :ok) == ""

      # Verify issue was transitioned to blocked
      updated_issue = Issues.get_issue!(issue.id)
      assert updated_issue.status == :blocked
    end
  end

  describe "webhook non-PR events" do
    test "returns 200 for non-PR payloads without error", %{conn: conn} do
      payload = %{"action" => "created", "ref" => "refs/heads/main"}

      conn = post(conn, "/api/github/webhook", payload)

      assert response(conn, :ok) == ""
    end

    test "returns 200 for unlinked PR", %{conn: conn, project: project} do
      # Use a PR URL that is not linked to any issue
      payload = build_pr_payload("opened", "https://github.com/other/repo/pull/999")
      conn = post_signed_webhook(conn, payload, project.github_webhook_secret)

      # Should return 200 but take no action (no issue linked)
      assert response(conn, :ok) == ""
    end
  end

  describe "branch-based auto-link" do
    setup do
      {:ok, project} =
        Projects.create_project(%{
          name: "Autolink Project",
          prefix: "AL",
          github_webhook_secret: "autolink-secret",
          repo_url: "https://github.com/autolink-org/repo"
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Auto-link target",
          description: "PR opened with no set_pr_url",
          status: :todo,
          priority: :medium,
          project_id: project.id
        })

      # Sanity: identifier was generated and PR is not linked yet.
      assert issue.identifier =~ ~r/^AL-\d+$/
      assert is_nil(issue.github_pr_url)

      %{project: project, issue: issue}
    end

    test "PR opened on convention branch auto-links the issue", %{
      conn: conn,
      project: project,
      issue: issue
    } do
      pr_url = "https://github.com/autolink-org/repo/pull/77"
      branch = "#{issue.identifier}/some-slug"

      payload =
        build_autolink_payload(
          "opened",
          pr_url,
          branch,
          project.repo_url
        )

      conn = post_signed_webhook(conn, payload, project.github_webhook_secret)

      assert response(conn, :ok) == ""

      reloaded = Issues.get_issue!(issue.id)
      assert reloaded.github_pr_url == pr_url
      assert reloaded.status == :in_review

      comments = Cympho.Comments.list_comments(issue.id)

      assert Enum.any?(comments, fn c ->
               c.author_type == "system" and
                 String.contains?(c.body, "[auto-link]") and
                 String.contains?(c.body, branch)
             end)
    end

    test "refuses to overwrite an issue already linked to a different PR", %{
      conn: conn,
      project: project,
      issue: issue
    } do
      {:ok, _} =
        Issues.update_issue(issue, %{
          github_pr_url: "https://github.com/autolink-org/repo/pull/40"
        })

      other_pr_url = "https://github.com/autolink-org/repo/pull/77"
      branch = "#{issue.identifier}/colliding-slug"

      payload =
        build_autolink_payload("opened", other_pr_url, branch, project.repo_url)

      conn = post_signed_webhook(conn, payload, project.github_webhook_secret)

      assert response(conn, :ok) == ""

      reloaded = Issues.get_issue!(issue.id)
      assert reloaded.github_pr_url == "https://github.com/autolink-org/repo/pull/40"
    end
  end

  # Helper functions

  defp build_pr_payload(action, pr_url, extra_pr_attrs \\ %{}) do
    pr_attrs =
      Map.merge(
        %{
          "html_url" => pr_url,
          "title" => "Test PR",
          "merged" => false,
          "head" => %{"ref" => "test-branch"}
        },
        extra_pr_attrs
      )

    %{
      "action" => action,
      "pull_request" => pr_attrs,
      "repository" => %{
        "full_name" => "owner/repo"
      }
    }
  end

  defp build_autolink_payload(action, pr_url, branch, project_repo_url) do
    %{
      "action" => action,
      "pull_request" => %{
        "html_url" => pr_url,
        "title" => "Auto-link Test PR",
        "merged" => false,
        "head" => %{
          "ref" => branch,
          "repo" => %{"html_url" => project_repo_url}
        },
        "base" => %{
          "ref" => "main",
          "repo" => %{"html_url" => project_repo_url}
        }
      },
      "repository" => %{"full_name" => "autolink-org/repo"}
    }
  end

  defp compute_signature(payload, secret) do
    payload_json = Jason.encode!(payload)

    :crypto.mac(:hmac, :sha256, secret, payload_json)
    |> Base.encode16(case: :lower)
    |> then(&"sha256=#{&1}")
  end

  defp post_signed_webhook(conn, payload, secret) do
    payload_json = Jason.encode!(payload)
    signature = compute_signature(payload, secret)

    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-hub-signature-256", signature)
    |> post("/api/github/webhook", payload_json)
  end

  defp post_signed_webhook_with_delivery(conn, payload, secret, delivery_id) do
    payload_json = Jason.encode!(payload)
    signature = compute_signature(payload, secret)

    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-hub-signature-256", signature)
    |> put_req_header("x-github-delivery", delivery_id)
    |> post("/api/github/webhook", payload_json)
  end
end
