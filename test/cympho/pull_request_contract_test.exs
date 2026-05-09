defmodule Cympho.PullRequestContractTest do
  use ExUnit.Case, async: true

  alias Cympho.PullRequestContract

  describe "branch/title/body contract" do
    test "builds branch and PR title with the issue identifier" do
      issue = %{identifier: "CYM-42", title: "Improve contract nudges"}

      assert PullRequestContract.branch_name(issue) == "CYM-42/improve-contract-nudges"
      assert PullRequestContract.title(issue) == "CYM-42: Improve contract nudges"
    end

    test "renders a checklist-backed PR body template" do
      issue = %{identifier: "CYM-42", title: "Improve contract nudges"}
      body = PullRequestContract.body_template(issue)

      for heading <- PullRequestContract.required_headings() do
        assert body =~ heading
      end

      assert body =~ "- [ ] Implement the scoped change for CYM-42"
      assert body =~ "- [ ] Run focused tests for the changed area"
      assert PullRequestContract.audit_body(body).status == :ok
    end

    test "prompt block tells agents how to publish reviewable PRs" do
      issue = %{identifier: "CYM-42", title: "Improve contract nudges"}
      prompt = PullRequestContract.prompt_block(issue)

      assert prompt =~ "Branch name must include the issue id"
      assert prompt =~ "`CYM-42/improve-contract-nudges`"
      assert prompt =~ "`CYM-42: Improve contract nudges`"
      assert prompt =~ "Task List"
      assert prompt =~ "Validation"
      assert prompt =~ "GitHub checkboxes"
      assert prompt =~ "Use this PR body template"
      assert prompt =~ "## Risk and Rollback"
      assert prompt =~ "set_pr_url"
      assert prompt =~ "code_change"
    end

    test "builds a repair packet with exact expected PR fields and commands" do
      issue = %{
        identifier: "CYM-42",
        title: "Improve contract nudges",
        github_pr_url: "https://github.com/owner/repo/pull/42"
      }

      pr_quality = %{
        "gaps" => [
          %{
            "label" => "Branch name",
            "detail" => "Expected branch to include `CYM-42`; got `feature/pr-work`."
          },
          %{
            "label" => "Task List checkboxes",
            "detail" => "Task List must include GitHub checkbox items."
          }
        ]
      }

      packet = PullRequestContract.repair_packet(issue, pr_quality)

      assert packet.branch_name == "CYM-42/improve-contract-nudges"
      assert packet.title == "CYM-42: Improve contract nudges"
      assert packet.body_template =~ "## Task List"
      assert packet.missing_fields == ["Branch name", "Task List checkboxes"]

      assert Enum.join(packet.commands, "\n") =~
               "gh pr edit https://github.com/owner/repo/pull/42"

      assert packet.after_repair =~ "Re-emit `set_pr_url`"

      markdown = PullRequestContract.repair_packet_markdown(issue, pr_quality)
      assert markdown =~ "## PR repair packet"
      assert markdown =~ "Expected branch"
      assert markdown =~ "Suggested commands"
      assert markdown =~ "PR body template"
    end

    test "audits PR metadata for issue id, sections, and checkboxes" do
      issue = %{identifier: "CYM-42", title: "Improve contract nudges"}

      metadata = %{
        title: "CYM-42: Improve contract nudges",
        branch_name: "CYM-42/improve-contract-nudges",
        body: PullRequestContract.body_template(issue),
        url: "https://github.com/owner/repo/pull/42"
      }

      assert %{status: :ready, gaps: []} = PullRequestContract.audit_metadata(issue, metadata)
    end

    test "explains PR metadata gaps" do
      issue = %{identifier: "CYM-42", title: "Improve contract nudges"}

      assert %{status: :attention, gaps: gaps} =
               PullRequestContract.audit_metadata(issue, %{
                 title: "Improve contract nudges",
                 branch_name: "feature/pr-work",
                 body: "Thin body"
               })

      assert Enum.map(gaps, & &1.key) == [
               :branch_name,
               :title,
               :body_headings,
               :task_checkboxes,
               :validation_checkboxes
             ]
    end

    test "fetches and audits PR metadata" do
      issue = %{identifier: "CYM-42", title: "Improve contract nudges"}

      body =
        Jason.encode!(%{
          "title" => "CYM-42: Improve contract nudges",
          "body" => PullRequestContract.body_template(issue),
          "html_url" => "https://github.com/owner/repo/pull/42",
          "number" => 42,
          "state" => "open",
          "head" => %{"ref" => "CYM-42/improve-contract-nudges"}
        })

      http_fn = fn _url, _headers, _finch -> {:ok, %Finch.Response{status: 200, body: body}} end

      assert %{status: :ready, status_label: "PR ready"} =
               PullRequestContract.check_url(issue, "https://github.com/owner/repo/pull/42",
                 http_fn: http_fn,
                 token: "test",
                 source: "manual_button"
               )
    end

    test "serializes rich monitor state for the quality loop" do
      issue = %{identifier: "CYM-42", title: "Improve contract nudges"}

      audit =
        PullRequestContract.audit_metadata(
          issue,
          %{
            title: "Weak title",
            branch_name: "feature/pr-work",
            body: "Thin body",
            url: "https://github.com/owner/repo/pull/42"
          },
          source: "github_webhook:synchronize"
        )

      payload = PullRequestContract.monitor_state_payload(audit)

      assert payload["status"] == "attention"
      assert payload["passed"] == false
      assert payload["checked_source"] == "github_webhook:synchronize"
      assert payload["last_checked_at"] == payload["checked_at"]
      assert "Branch name" in payload["missing_fields"]
      assert "Task List checkboxes" in payload["missing_fields"]
    end

    test "returns an unchecked result when GitHub metadata cannot be fetched" do
      issue = %{identifier: "CYM-42", title: "Improve contract nudges"}

      assert %{status: :unchecked, summary: summary, gaps: []} =
               PullRequestContract.check_url(issue, "https://github.com/owner/repo/pull/42")

      assert summary =~ "GitHub token is not configured"
    end
  end
end
