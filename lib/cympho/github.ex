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
  def build_branch_name(%{prefix: prefix, sequence: seq, title: title}) do
    slug =
      title
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> truncate_slug(prefix, seq)

    "#{prefix}-#{seq}/#{slug}"
  end

  defp truncate_slug(slug, prefix, seq) do
    prefix_len = String.length("#{prefix}-#{seq}/")
    max_slug_len = max(80 - prefix_len, 1)

    if String.length(slug) > max_slug_len do
      slug
      |> String.slice(0, max_slug_len)
      |> String.trim("-")
    else
      slug
    end
  end

  defp github_token do
    Application.get_env(:cympho, :github_token)
  end
end
