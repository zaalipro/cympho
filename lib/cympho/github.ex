defmodule Cympho.Github do
  @moduledoc """
  GitHub API helpers: repo URL parsing, branch existence checks,
  and branch name generation from issue metadata.
  """

  @finch_name Application.compile_env(:cympho, :finch_name, Cympho.Finch)

  @doc """
  Parses a GitHub repository URL into `{owner, repo}`.

  Accepts both HTTPS and SSH formats:

    * `https://github.com/owner/repo`
    * `https://github.com/owner/repo.git`
    * `git@github.com:owner/repo.git`
    * `git@github.com:owner/repo`

  Returns `{:ok, {owner, repo}}` or `{:error, :invalid_url}`.
  """
  def parse_repo_url(url) when is_binary(url) do
    cond do
      String.starts_with?(url, "https://github.com/") ->
        parse_https(url)

      String.starts_with?(url, "git@github.com:") ->
        parse_ssh(url)

      true ->
        {:error, :invalid_url}
    end
  end

  def parse_repo_url(_), do: {:error, :invalid_url}

  @doc """
  Parses a GitHub pull request URL into `{owner, repo, number}`.

  Accepts `https://github.com/owner/repo/pull/123`.
  """
  def parse_pull_request_url(url) when is_binary(url) do
    url
    |> URI.parse()
    |> case do
      %URI{scheme: "https", host: "github.com", path: path} ->
        path
        |> String.trim_leading("/")
        |> String.trim_trailing("/")
        |> String.split("/")
        |> case do
          [owner, repo, "pull", number] ->
            with {number, ""} <- Integer.parse(number) do
              {:ok, {owner, repo, number}}
            else
              _ -> {:error, :invalid_url}
            end

          _ ->
            {:error, :invalid_url}
        end

      _ ->
        {:error, :invalid_url}
    end
  end

  def parse_pull_request_url(_), do: {:error, :invalid_url}

  defp parse_https(url) do
    url
    |> String.trim_leading("https://github.com/")
    |> String.trim_trailing(".git")
    |> String.split("/")
    |> case do
      [owner, repo] -> {:ok, {owner, repo}}
      _ -> {:error, :invalid_url}
    end
  end

  defp parse_ssh(url) do
    url
    |> String.trim_leading("git@github.com:")
    |> String.trim_trailing(".git")
    |> String.split("/")
    |> case do
      [owner, repo] -> {:ok, {owner, repo}}
      _ -> {:error, :invalid_url}
    end
  end

  @doc """
  Checks whether a branch exists in a GitHub repository via the API.

  Uses the `GET /repos/{owner}/{repo}/branches/{branch}` endpoint.
  A GitHub token is required for authentication.

  Returns `{:ok, true}`, `{:ok, false}`, or `{:error, reason}`.

  ## Options

    * `:token` — GitHub API token (falls back to `:github_token` app env)
    * `:finch` — Finch pool name (defaults to `Cympho.Finch`)
    * `:http_fn` — function `(url, headers, finch) -> result` for testing
  """
  def branch_exists?(owner, repo, branch, opts \\ []) do
    http_fn = Keyword.get(opts, :http_fn, &default_http_request/3)
    finch = Keyword.get(opts, :finch, @finch_name)
    token = Keyword.get(opts, :token) || github_token()

    url = "https://api.github.com/repos/#{owner}/#{repo}/branches/#{URI.encode(branch)}"

    headers = [
      {"authorization", "Bearer #{token}"},
      {"accept", "application/vnd.github+json"},
      {"user-agent", "cympho"}
    ]

    case http_fn.(url, headers, finch) do
      {:ok, %Finch.Response{status: 200}} ->
        {:ok, true}

      {:ok, %Finch.Response{status: 404}} ->
        {:ok, false}

      {:ok, %Finch.Response{status: status, body: body}} ->
        {:error, {:unexpected_status, status, body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  @doc """
  Fetches pull request metadata needed by the PR quality gate.

  A GitHub token is required so private repos work and tests/dev do not make
  accidental unauthenticated network calls.
  """
  def fetch_pull_request(url, opts \\ [])

  def fetch_pull_request(url, opts) when is_binary(url) do
    with {:ok, {owner, repo, number}} <- parse_pull_request_url(url) do
      fetch_pull_request(owner, repo, number, opts)
    end
  end

  def fetch_pull_request(_url, _opts), do: {:error, :invalid_url}

  def fetch_pull_request(owner, repo, number, opts)
      when is_binary(owner) and is_binary(repo) and is_integer(number) do
    http_fn = Keyword.get(opts, :http_fn, &default_http_request/3)
    finch = Keyword.get(opts, :finch, @finch_name)
    token = Keyword.get(opts, :token) || github_token()

    if token in [nil, ""] do
      {:error, :missing_token}
    else
      url = "https://api.github.com/repos/#{owner}/#{repo}/pulls/#{number}"

      headers = [
        {"authorization", "Bearer #{token}"},
        {"accept", "application/vnd.github+json"},
        {"user-agent", "cympho"}
      ]

      case http_fn.(url, headers, finch) do
        {:ok, %Finch.Response{status: 200, body: body}} ->
          parse_pull_request_body(body)

        {:ok, %Finch.Response{status: 404}} ->
          {:error, :not_found}

        {:ok, %Finch.Response{status: status, body: body}} ->
          {:error, {:unexpected_status, status, body}}

        {:error, reason} ->
          {:error, {:request_failed, reason}}
      end
    end
  end

  def fetch_pull_request(_owner, _repo, _number, _opts), do: {:error, :invalid_url}

  @doc """
  Normalizes a GitHub pull_request webhook payload into the metadata shape used
  by the PR quality gate.
  """
  def pull_request_metadata(%{} = pr) do
    %{
      title: pr["title"] || "",
      body: pr["body"] || "",
      branch_name: get_in(pr, ["head", "ref"]) || "",
      url: pr["html_url"],
      number: pr["number"],
      state: pr["state"]
    }
  end

  def pull_request_metadata(_pr), do: %{}

  @doc """
  Fetches the list of reviews on a pull request. Returns
  `{:ok, [%{state, body, user, submitted_at, id, ...}]}` on success.

  Used by the webhook handler to enrich a `pull_request_review` event with
  the full review payload, and by the CTO agent to read prior review state
  before deciding whether to `force_fix_pr` again.
  """
  @spec fetch_pull_request_reviews(String.t(), keyword()) ::
          {:ok, list(map())} | {:error, term()}
  def fetch_pull_request_reviews(url, opts \\ [])

  def fetch_pull_request_reviews(url, opts) when is_binary(url) do
    with {:ok, {owner, repo, number}} <- parse_pull_request_url(url) do
      do_get_json(
        "https://api.github.com/repos/#{owner}/#{repo}/pulls/#{number}/reviews",
        opts
      )
    end
  end

  @doc """
  Fetches line-level review comments on a pull request.
  Returns `{:ok, [%{path, line, body, user, ...}]}` on success.
  """
  @spec fetch_pull_request_review_comments(String.t(), keyword()) ::
          {:ok, list(map())} | {:error, term()}
  def fetch_pull_request_review_comments(url, opts \\ [])

  def fetch_pull_request_review_comments(url, opts) when is_binary(url) do
    with {:ok, {owner, repo, number}} <- parse_pull_request_url(url) do
      do_get_json(
        "https://api.github.com/repos/#{owner}/#{repo}/pulls/#{number}/comments",
        opts
      )
    end
  end

  @doc """
  Fetches the list of file changes for a pull request. Used by the CTO
  agent's PR-review preamble to surface "since last review, files X/Y/Z
  changed."
  """
  @spec fetch_pull_request_files(String.t(), keyword()) ::
          {:ok, list(map())} | {:error, term()}
  def fetch_pull_request_files(url, opts \\ [])

  def fetch_pull_request_files(url, opts) when is_binary(url) do
    with {:ok, {owner, repo, number}} <- parse_pull_request_url(url) do
      do_get_json(
        "https://api.github.com/repos/#{owner}/#{repo}/pulls/#{number}/files",
        opts
      )
    end
  end

  @doc """
  Merges a pull request via GitHub's merge API. Caller is responsible for
  verifying the PR is approved + green + mergeable before calling.

  Options:
    * `:method` — `"merge" | "squash" | "rebase"` (default `"squash"`)
    * `:commit_title` — optional commit title
    * `:commit_message` — optional commit message
    * `:sha` — optional head SHA to require for the merge

  Returns `{:ok, %{sha, merged: true}}` on success or
  `{:error, {:not_mergeable, body}}` / `{:error, {:unexpected_status, status, body}}`.
  """
  @spec merge_pr(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def merge_pr(url, opts \\ [])

  def merge_pr(url, opts) when is_binary(url) do
    with {:ok, {owner, repo, number}} <- parse_pull_request_url(url) do
      api_url = "https://api.github.com/repos/#{owner}/#{repo}/pulls/#{number}/merge"

      payload =
        %{}
        |> maybe_put("commit_title", Keyword.get(opts, :commit_title))
        |> maybe_put("commit_message", Keyword.get(opts, :commit_message))
        |> maybe_put("sha", Keyword.get(opts, :sha))
        |> Map.put("merge_method", Keyword.get(opts, :method, "squash"))

      case do_request(:put, api_url, payload, opts) do
        {:ok, %Finch.Response{status: 200, body: body}} ->
          parse_merge_response(body)

        {:ok, %Finch.Response{status: 405, body: body}} ->
          {:error, {:not_mergeable, body}}

        {:ok, %Finch.Response{status: 409, body: body}} ->
          {:error, {:merge_conflict, body}}

        {:ok, %Finch.Response{status: status, body: body}} ->
          {:error, {:unexpected_status, status, body}}

        {:error, reason} ->
          {:error, {:request_failed, reason}}
      end
    end
  end

  @doc """
  Creates a pull request review (approve, comment, request_changes) with
  optional inline comments.

  Required:
    * `:event` — `"APPROVE" | "REQUEST_CHANGES" | "COMMENT"`
    * `:body` — review body markdown

  Optional:
    * `:comments` — list of `%{path, line, body}` line-level comments
    * `:commit_id` — pin the review to a specific commit
  """
  @spec create_review(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def create_review(url, opts) when is_binary(url) do
    with :ok <- ensure_event(opts[:event]),
         {:ok, {owner, repo, number}} <- parse_pull_request_url(url) do
      api_url = "https://api.github.com/repos/#{owner}/#{repo}/pulls/#{number}/reviews"

      payload =
        %{
          "event" => opts[:event],
          "body" => opts[:body] || ""
        }
        |> maybe_put("comments", normalize_review_comments(opts[:comments]))
        |> maybe_put("commit_id", opts[:commit_id])

      case do_request(:post, api_url, payload, opts) do
        {:ok, %Finch.Response{status: status, body: body}} when status in 200..299 ->
          Jason.decode(body)

        {:ok, %Finch.Response{status: status, body: body}} ->
          {:error, {:unexpected_status, status, body}}

        {:error, reason} ->
          {:error, {:request_failed, reason}}
      end
    end
  end

  @doc """
  Updates a PR's branch with the latest base. GitHub's
  POST /repos/.../pulls/N/update-branch endpoint. Used to reduce conflict
  surface before attempting a merge.
  """
  @spec update_branch(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def update_branch(url, opts \\ []) when is_binary(url) do
    with {:ok, {owner, repo, number}} <- parse_pull_request_url(url) do
      api_url = "https://api.github.com/repos/#{owner}/#{repo}/pulls/#{number}/update-branch"
      payload = maybe_put(%{}, "expected_head_sha", opts[:expected_head_sha])

      case do_request(:put, api_url, payload, opts) do
        {:ok, %Finch.Response{status: status, body: body}} when status in 200..299 ->
          Jason.decode(body)

        {:ok, %Finch.Response{status: status, body: body}} ->
          {:error, {:unexpected_status, status, body}}

        {:error, reason} ->
          {:error, {:request_failed, reason}}
      end
    end
  end

  defp ensure_event(event) when event in ["APPROVE", "REQUEST_CHANGES", "COMMENT"], do: :ok
  defp ensure_event(_), do: {:error, :invalid_review_event}

  defp normalize_review_comments(nil), do: nil

  defp normalize_review_comments(comments) when is_list(comments) do
    Enum.map(comments, fn c ->
      c
      |> Map.take(["path", "line", "body", "side", "start_line"])
      |> Map.merge(%{
        "path" => c["path"] || c[:path],
        "line" => c["line"] || c[:line],
        "body" => c["body"] || c[:body]
      })
    end)
  end

  defp parse_merge_response(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, %{sha: decoded["sha"], merged: decoded["merged"] == true}}
      {:error, error} -> {:error, {:invalid_json, Exception.message(error)}}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Generic GET helper that returns the decoded JSON list/map.
  defp do_get_json(url, opts) do
    case do_request(:get, url, nil, opts) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        Jason.decode(body)

      {:ok, %Finch.Response{status: 404}} ->
        {:error, :not_found}

      {:ok, %Finch.Response{status: status, body: body}} ->
        {:error, {:unexpected_status, status, body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  # Single dispatch for both reads and writes. `body` is `nil` for GETs;
  # otherwise it's a map encoded as JSON. Tests pass `:http_fn` to inject a
  # mock that returns a `Finch.Response`-shaped struct.
  defp do_request(method, url, body, opts) do
    finch = Keyword.get(opts, :finch, @finch_name)
    token = Keyword.get(opts, :token) || github_token()

    if token in [nil, ""] do
      {:error, :missing_token}
    else
      headers = [
        {"authorization", "Bearer #{token}"},
        {"accept", "application/vnd.github+json"},
        {"content-type", "application/json"},
        {"user-agent", "cympho"}
      ]

      case Keyword.get(opts, :http_fn) do
        nil -> default_http_mutation(method, url, headers, body, finch)
        fun -> fun.(method, url, headers, body, finch)
      end
    end
  end

  defp default_http_mutation(method, url, headers, nil, finch) do
    Finch.build(method, url, headers) |> Finch.request(finch)
  end

  defp default_http_mutation(method, url, headers, body, finch) when is_map(body) do
    Finch.build(method, url, headers, Jason.encode!(body)) |> Finch.request(finch)
  end

  defp parse_pull_request_body(body) do
    with {:ok, decoded} <- Jason.decode(body) do
      {:ok,
       %{
         title: decoded["title"] || "",
         body: decoded["body"] || "",
         branch_name: get_in(decoded, ["head", "ref"]) || "",
         url: decoded["html_url"],
         number: decoded["number"],
         state: decoded["state"]
       }}
    else
      {:error, error} -> {:error, {:invalid_json, Exception.message(error)}}
    end
  end

  defp default_http_request(url, headers, finch) do
    Finch.build(:get, url, headers) |> Finch.request(finch)
  end

  @doc """
  Builds a git branch name from an issue prefix, sequence number, and title.

  Normalizes the title: downcases, replaces non-alphanumeric runs with single
  hyphens, strips leading/trailing hyphens, and truncates to keep the total
  branch name under 80 characters.

  ## Examples

      iex> build_branch_name(%{prefix: "LLM", sequence: 42, title: "Add login page"})
      "LLM-42/add-login-page"

      iex> build_branch_name(%{prefix: "LLM", sequence: 1, title: "Fix: CSS & HTML issues!!!"})
      "LLM-1/fix-css-html-issues"
  """
  def build_branch_name(%{identifier: identifier, title: title})
      when is_binary(identifier) and identifier != "" do
    slug =
      title
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> empty_slug()
      |> truncate_slug(identifier)

    "#{identifier}/#{slug}"
  end

  def build_branch_name(%{prefix: prefix, sequence: seq, title: title}) do
    slug =
      title
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> empty_slug()
      |> truncate_slug(prefix, seq)

    "#{prefix}-#{seq}/#{slug}"
  end

  defp truncate_slug(slug, identifier) do
    prefix_len = String.length("#{identifier}/")
    max_slug_len = max(80 - prefix_len, 1)

    if String.length(slug) > max_slug_len do
      slug
      |> String.slice(0, max_slug_len)
      |> String.trim("-")
      |> empty_slug()
    else
      slug
    end
  end

  defp truncate_slug(slug, prefix, seq) do
    prefix_len = String.length("#{prefix}-#{seq}/")
    max_slug_len = max(80 - prefix_len, 1)

    if String.length(slug) > max_slug_len do
      slug
      |> String.slice(0, max_slug_len)
      |> String.trim("-")
      |> empty_slug()
    else
      slug
    end
  end

  defp empty_slug(""), do: "work"
  defp empty_slug(slug), do: slug

  defp github_token do
    Application.get_env(:cympho, :github_token)
  end
end
