#!/usr/bin/env elixir
# Standalone test runner for Cympho.Github — no database required.
# Usage: elixir test/cympho/github_test_standalone.exs

# Add compiled deps to path
paths = Path.wildcard("_build/test/lib/*/ebin")
Enum.each(paths, &Code.append_path/1)

# Compile the module under test
Code.compile_file("lib/cympho/github.ex")

ExUnit.start()

defmodule Cympho.GithubTest do
  use ExUnit.Case, async: true

  alias Cympho.Github

  # ---------------------------------------------------------------------------
  # parse_repo_url/1
  # ---------------------------------------------------------------------------

  describe "parse_repo_url/1 — HTTPS format" do
    test "parses https://github.com/owner/repo" do
      assert {:ok, {"zaalipro", "cympho"}} = Github.parse_repo_url("https://github.com/zaalipro/cympho")
    end

    test "parses https://github.com/owner/repo.git" do
      assert {:ok, {"zaalipro", "cympho"}} = Github.parse_repo_url("https://github.com/zaalipro/cympho.git")
    end

    test "parses with different owner and repo" do
      assert {:ok, {"elixir-lang", "elixir"}} = Github.parse_repo_url("https://github.com/elixir-lang/elixir")
    end

    test "parses repo with hyphens" do
      assert {:ok, {"my-org", "my-cool-project"}} =
               Github.parse_repo_url("https://github.com/my-org/my-cool-project")
    end
  end

  describe "parse_repo_url/1 — SSH format" do
    test "parses git@github.com:owner/repo.git" do
      assert {:ok, {"zaalipro", "cympho"}} = Github.parse_repo_url("git@github.com:zaalipro/cympho.git")
    end

    test "parses git@github.com:owner/repo without .git suffix" do
      assert {:ok, {"zaalipro", "cympho"}} = Github.parse_repo_url("git@github.com:zaalipro/cympho")
    end

    test "parses with different owner and repo" do
      assert {:ok, {"elixir-lang", "elixir"}} = Github.parse_repo_url("git@github.com:elixir-lang/elixir.git")
    end
  end

  describe "parse_repo_url/1 — invalid inputs" do
    test "returns error for non-github URL" do
      assert {:error, :invalid_url} = Github.parse_repo_url("https://gitlab.com/owner/repo")
    end

    test "returns error for malformed URL" do
      assert {:error, :invalid_url} = Github.parse_repo_url("not-a-url")
    end

    test "returns error for nil" do
      assert {:error, :invalid_url} = Github.parse_repo_url(nil)
    end

    test "returns error for empty string" do
      assert {:error, :invalid_url} = Github.parse_repo_url("")
    end

    test "returns error for URL with too many path segments" do
      assert {:error, :invalid_url} = Github.parse_repo_url("https://github.com/owner/repo/extra")
    end

    test "returns error for URL with only owner" do
      assert {:error, :invalid_url} = Github.parse_repo_url("https://github.com/owner")
    end
  end

  # ---------------------------------------------------------------------------
  # branch_exists?/3
  # ---------------------------------------------------------------------------

  describe "branch_exists?/3 — mocked Finch responses" do
    test "returns {:ok, true} when API responds 200" do
      http_fn = fn _url, _headers, _finch ->
        {:ok, %Finch.Response{status: 200, body: "{}"}}
      end

      assert {:ok, true} = Github.branch_exists?("owner", "repo", "main", http_fn: http_fn, token: "test")
    end

    test "returns {:ok, false} when API responds 404" do
      http_fn = fn _url, _headers, _finch ->
        {:ok, %Finch.Response{status: 404, body: "{\"message\": \"Not Found\"}"}}
      end

      assert {:ok, false} = Github.branch_exists?("owner", "repo", "nonexistent", http_fn: http_fn, token: "test")
    end

    test "returns {:error, {:unexpected_status, 500, _}} for 500 response" do
      http_fn = fn _url, _headers, _finch ->
        {:ok, %Finch.Response{status: 500, body: "Internal Server Error"}}
      end

      assert {:error, {:unexpected_status, 500, "Internal Server Error"}} =
               Github.branch_exists?("owner", "repo", "main", http_fn: http_fn, token: "test")
    end

    test "returns {:error, {:unexpected_status, 403, _}} for rate-limited 403" do
      http_fn = fn _url, _headers, _finch ->
        {:ok, %Finch.Response{status: 403, body: "rate limited"}}
      end

      assert {:error, {:unexpected_status, 403, "rate limited"}} =
               Github.branch_exists?("owner", "repo", "main", http_fn: http_fn, token: "test")
    end

    test "returns {:error, {:request_failed, _}} on network error" do
      http_fn = fn _url, _headers, _finch ->
        {:error, %Mint.TransportError{reason: :econnrefused}}
      end

      assert {:error, {:request_failed, %Mint.TransportError{reason: :econnrefused}}} =
               Github.branch_exists?("owner", "repo", "main", http_fn: http_fn, token: "test")
    end

    test "passes correct URL to http_fn" do
      http_fn = fn url, _headers, _finch ->
        assert url == "https://api.github.com/repos/test-org/test-repo/branches/feature-branch"
        {:ok, %Finch.Response{status: 200, body: "{}"}}
      end

      Github.branch_exists?("test-org", "test-repo", "feature-branch", http_fn: http_fn, token: "test")
    end

    test "passes authorization header to http_fn" do
      http_fn = fn _url, headers, _finch ->
        assert List.keyfind(headers, "authorization", 0) == {"authorization", "Bearer my-secret-token"}
        {:ok, %Finch.Response{status: 200, body: "{}"}}
      end

      Github.branch_exists?("owner", "repo", "main", http_fn: http_fn, token: "my-secret-token")
    end

    test "URL-encodes branch names with slashes" do
      http_fn = fn url, _headers, _finch ->
        assert url == "https://api.github.com/repos/owner/repo/branches/feature/my-branch"
        {:ok, %Finch.Response{status: 200, body: "{}"}}
      end

      Github.branch_exists?("owner", "repo", "feature/my-branch", http_fn: http_fn, token: "test")
    end
  end

  # ---------------------------------------------------------------------------
  # build_branch_name/1
  # ---------------------------------------------------------------------------

  describe "build_branch_name/1" do
    test "builds standard branch name from issue" do
      issue = %{prefix: "LLM", sequence: 42, title: "Add login page"}
      assert Github.build_branch_name(issue) == "LLM-42/add-login-page"
    end

    test "lowercases the title" do
      issue = %{prefix: "LLM", sequence: 10, title: "Add LOGIN Page"}
      assert Github.build_branch_name(issue) == "LLM-10/add-login-page"
    end

    test "replaces special characters with hyphens" do
      issue = %{prefix: "LLM", sequence: 1, title: "Fix: CSS & HTML issues!!!"}
      assert Github.build_branch_name(issue) == "LLM-1/fix-css-html-issues"
    end

    test "replaces multiple spaces with single hyphen" do
      issue = %{prefix: "LLM", sequence: 5, title: "Fix   multiple    spaces"}
      assert Github.build_branch_name(issue) == "LLM-5/fix-multiple-spaces"
    end

    test "strips leading and trailing hyphens from slug" do
      issue = %{prefix: "LLM", sequence: 3, title: "!!!fix the bug!!!"}
      assert Github.build_branch_name(issue) == "LLM-3/fix-the-bug"
    end

    test "handles simple title with no special characters" do
      issue = %{prefix: "CORE", sequence: 100, title: "update readme"}
      assert Github.build_branch_name(issue) == "CORE-100/update-readme"
    end

    test "truncates long titles to keep branch name under 80 chars" do
      long_title = String.duplicate("a very long word ", 20)
      result = Github.build_branch_name(%{prefix: "LLM", sequence: 999, title: long_title})
      assert String.length(result) <= 80
      assert String.starts_with?(result, "LLM-999/")
    end

    test "handles numeric-only title" do
      issue = %{prefix: "LLM", sequence: 7, title: "12345"}
      assert Github.build_branch_name(issue) == "LLM-7/12345"
    end

    test "handles title with underscores" do
      issue = %{prefix: "LLM", sequence: 8, title: "add_new_feature"}
      assert Github.build_branch_name(issue) == "LLM-8/add-new-feature"
    end
  end
end
