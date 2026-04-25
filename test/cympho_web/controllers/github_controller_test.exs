defmodule CymphoWeb.GithubControllerTest do
  use CymphoWeb.ConnCase, async: true

  alias Cympho.Issues
  alias Cympho.Projects
  alias Cympho.Agents

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
      signature = compute_signature(payload, project.github_webhook_secret)

      conn =
        conn
        |> put_req_header("x-hub-signature-256", signature)
        |> post("/api/github/webhook", payload)

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
      signature = compute_signature(payload, project.github_webhook_secret)

      conn =
        conn
        |> put_req_header("x-hub-signature-256", signature)
        |> post("/api/github/webhook", payload)

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
      signature = compute_signature(payload, project.github_webhook_secret)

      conn =
        conn
        |> put_req_header("x-hub-signature-256", signature)
        |> post("/api/github/webhook", payload)

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

      signature = compute_signature(payload, project.github_webhook_secret)

      conn =
        conn
        |> put_req_header("x-hub-signature-256", signature)
        |> post("/api/github/webhook", payload)

      assert response(conn, :ok) == ""

      # Verify a system comment was added
      updated_issue = Issues.get_issue!(issue.id)
      assert length(updated_issue.comments) > 0
    end

    test "PR merged (closed with merged=true) transitions issue to done", %{
      conn: conn,
      issue: issue,
      project: project
    } do
      payload = build_pr_payload("closed", issue.github_pr_url, %{"merged" => true})
      signature = compute_signature(payload, project.github_webhook_secret)

      conn =
        conn
        |> put_req_header("x-hub-signature-256", signature)
        |> post("/api/github/webhook", payload)

      assert response(conn, :ok) == ""

      # Verify issue was transitioned to done
      updated_issue = Issues.get_issue!(issue.id)
      assert updated_issue.status == :done
    end

    test "PR closed without merge transitions issue to blocked", %{
      conn: conn,
      issue: issue,
      project: project
    } do
      payload = build_pr_payload("closed", issue.github_pr_url, %{"merged" => false})
      signature = compute_signature(payload, project.github_webhook_secret)

      conn =
        conn
        |> put_req_header("x-hub-signature-256", signature)
        |> post("/api/github/webhook", payload)

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
      signature = compute_signature(payload, project.github_webhook_secret)

      conn =
        conn
        |> put_req_header("x-hub-signature-256", signature)
        |> post("/api/github/webhook", payload)

      # Should return 200 but take no action (no issue linked)
      assert response(conn, :ok) == ""
    end
  end

  describe "github_pr_url validation in Issue" do
    test "accepts valid GitHub PR URL format" do
      attrs = %{
        title: "Valid PR URL Test",
        description: "Testing URL validation",
        github_pr_url: "https://github.com/owner/repo/pull/123"
      }

      assert {:ok, _issue} = Issues.create_issue(attrs)
    end

    test "accepts GitHub PR URL with trailing slash" do
      attrs = %{
        title: "Valid PR URL Test",
        description: "Testing URL validation",
        github_pr_url: "https://github.com/owner/repo/pull/123/"
      }

      assert {:ok, _issue} = Issues.create_issue(attrs)
    end

    test "rejects invalid GitHub PR URL" do
      attrs = %{
        title: "Invalid PR URL Test",
        description: "Testing URL validation",
        github_pr_url: "https://gitlab.com/owner/repo/pull/123"
      }

      assert {:error, changeset} = Issues.create_issue(attrs)
      assert Keyword.has_key?(changeset.errors, :github_pr_url)
    end

    test "rejects non-GitHub URL" do
      attrs = %{
        title: "Non-GitHub URL Test",
        description: "Testing URL validation",
        github_pr_url: "https://github.com/owner/repo/issues/123"
      }

      assert {:error, changeset} = Issues.create_issue(attrs)
      assert Keyword.has_key?(changeset.errors, :github_pr_url)
    end

    test "accepts empty/nil github_pr_url" do
      attrs = %{
        title: "Nil PR URL Test",
        description: "Testing URL validation"
      }

      assert {:ok, issue} = Issues.create_issue(attrs)
      assert issue.github_pr_url == nil
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

  defp compute_signature(payload, secret) do
    payload_json = Jason.encode!(payload)

    :crypto.mac(:hmac, :sha256, secret, payload_json)
    |> Base.encode16(case: :lower)
    |> then(&"sha256=#{&1}")
  end
end
