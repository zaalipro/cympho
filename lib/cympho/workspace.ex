defmodule Cympho.Workspace do
  @moduledoc """
  The Workspace context manages per-issue working directories.

  Each issue gets its own git-cloned workspace under a configurable root,
  allowing isolated agent work without conflicts.
  """

  @workspace_root Application.compile_env(:cympho, :workspace_root, "/tmp/cympho/workspaces")
  @recoverable_scaffold_dirs [".agents", ".codex", ".git"]

  alias Cympho.PullRequestContract

  @doc """
  Returns the workspace root directory.
  """
  def workspace_root, do: @workspace_root

  @unsafe_cwd_prefixes ~w(/etc /usr /bin /sbin /var /System /private/etc)

  @doc """
  Returns true when `cwd` is an expanded absolute host path that is safe
  to use as a project or execution workspace directory.
  """
  @spec safe_host_cwd?(term()) :: boolean()
  def safe_host_cwd?(cwd) when is_binary(cwd) do
    trimmed = String.trim(cwd)

    cond do
      trimmed == "" ->
        false

      not String.starts_with?(trimmed, "/") ->
        false

      Enum.any?(Path.split(trimmed), &(&1 == "..")) ->
        false

      true ->
        expanded = Path.expand(trimmed)
        expanded != "/" and not unsafe_cwd_prefix?(expanded)
    end
  end

  def safe_host_cwd?(_cwd), do: false

  defp unsafe_cwd_prefix?(path) do
    Enum.any?(@unsafe_cwd_prefixes, fn prefix ->
      path == prefix or String.starts_with?(path, prefix <> "/")
    end)
  end

  @doc """
  Returns the workspace path for a given issue.
  """
  def workspace_path(issue_id) when is_binary(issue_id) do
    Path.join([@workspace_root, "issue-#{issue_id}"])
  end

  def workspace_path(%{id: issue_id}) do
    workspace_path(to_string(issue_id))
  end

  @doc """
  Creates a workspace for an issue by cloning the project repo.

  Returns `{:ok, workspace_path}` or `{:error, reason}`.
  """
  def create_for_issue(%{id: issue_id, project_id: project_id} = issue) do
    path = workspace_path(issue_id)

    with :ok <- ensure_root_exists(),
         :ok <- validate_path_is_safe(path),
         {:ok, _} <- clone_repo(project_id, path),
         {:ok, _branch} <- checkout_issue_branch(path, issue) do
      {:ok, path}
    end
  end

  @doc """
  Ensures an issue has a usable runtime workspace.

  Repo-configured issues are cloned on first use. An absent or empty path is
  safe to provision, as is the known empty control-directory scaffold left by
  local agent CLIs. Existing Git checkouts are reused. Any other non-empty,
  non-Git path is preserved and rejected rather than overwritten.

  Issues without a configured repository retain the plain-directory fallback.
  """
  def ensure_for_issue(%{id: issue_id} = issue) do
    path = workspace_path(issue_id)

    with :ok <- ensure_root_exists(),
         :ok <- validate_path_is_safe(path) do
      case repo_url_for_issue(issue) do
        {:ok, _repo_url} -> ensure_repo_workspace(issue, path)
        {:error, :no_repo_configured} -> ensure_plain_workspace(path)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Writes the issue prompt to a markdown file in the workspace.

  Returns `:ok` or `{:error, reason}`.
  """
  def write_prompt_file(workspace_path, prompt) when is_binary(workspace_path) do
    with :ok <- validate_path_is_safe(workspace_path) do
      prompt_path = Path.join(workspace_path, "PROMPT.md")

      case File.write(prompt_path, prompt) do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Removes the workspace directory for a given issue.

  Returns `:ok` or `{:error, reason}`.
  """
  def remove_issue_workspaces(%{id: issue_id}) do
    path = workspace_path(issue_id)
    remove_workspace(path)
  end

  @doc """
  Removes a workspace directory.

  Returns `:ok` or `{:error, reason}`.
  """
  def remove_workspace(path) when is_binary(path) do
    with :ok <- validate_path_is_safe(path) do
      case File.rm_rf(path) do
        {:ok, _} -> :ok
        {:error, reason, _} -> {:error, reason}
      end
    end
  end

  defp ensure_root_exists do
    case File.mkdir_p(@workspace_root) do
      :ok -> :ok
      {:error, reason} -> {:error, {:cannot_create_root, reason}}
    end
  end

  defp validate_path_is_safe(path) do
    root = Path.expand(@workspace_root)
    expanded = Path.expand(path)

    if String.starts_with?(expanded, root) do
      :ok
    else
      {:error, :path_outside_workspace}
    end
  end

  defp clone_repo(project_id, path) do
    case get_repo_url(project_id) do
      {:ok, repo_url} ->
        System.cmd("git", ["clone", "--quiet", repo_url, path])
        |> case do
          {_output, 0} -> {:ok, path}
          {error, exit_code} -> {:error, {:git_clone_failed, exit_code, error}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp repo_url_for_issue(%{project_id: project_id}) when is_binary(project_id),
    do: get_repo_url(project_id)

  defp repo_url_for_issue(_issue), do: {:error, :no_repo_configured}

  defp ensure_repo_workspace(issue, path) do
    cond do
      git_workspace?(path) ->
        {:ok, path}

      not File.exists?(path) ->
        create_for_issue(issue)

      recoverable_scaffold?(path) ->
        with :ok <- remove_empty_scaffold(path) do
          create_for_issue(issue)
        end

      true ->
        {:error, {:workspace_not_git_repo, path}}
    end
  end

  defp ensure_plain_workspace(path) do
    case File.mkdir_p(path) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, {:cannot_create_workspace, reason}}
    end
  end

  defp git_workspace?(path) do
    if direct_directory?(path) do
      case System.cmd("git", ["-C", path, "rev-parse", "--show-prefix"], stderr_to_stdout: true) do
        {prefix, 0} -> String.trim(prefix) == ""
        {_output, _exit_code} -> false
      end
    else
      false
    end
  end

  defp recoverable_scaffold?(path) do
    if direct_directory?(path) do
      case File.ls(path) do
        {:ok, entries} -> Enum.all?(entries, &(&1 in @recoverable_scaffold_dirs))
        {:error, _reason} -> false
      end
    else
      false
    end
  end

  defp direct_directory?(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> true
      _ -> false
    end
  end

  # Only empty directories with the allowlisted control names are removed.
  # File.rmdir/1 refuses non-empty directories, so a concurrent writer turns
  # this into a safe failure instead of losing its files.
  defp remove_empty_scaffold(path) do
    with {:ok, entries} <- File.ls(path),
         true <- Enum.all?(entries, &(&1 in @recoverable_scaffold_dirs)),
         :ok <- remove_empty_scaffold_entries(path, entries),
         :ok <- File.rmdir(path) do
      :ok
    else
      _ -> {:error, {:workspace_not_git_repo, path}}
    end
  end

  defp remove_empty_scaffold_entries(path, entries) do
    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      case File.rmdir(Path.join(path, entry)) do
        :ok -> {:cont, :ok}
        {:error, _reason} -> {:halt, {:error, :not_empty}}
      end
    end)
  end

  defp checkout_issue_branch(path, issue) do
    branch_name = PullRequestContract.branch_name(issue)

    case System.cmd("git", ["checkout", "-B", branch_name], cd: path) do
      {_output, 0} -> {:ok, branch_name}
      {error, exit_code} -> {:error, {:git_checkout_failed, exit_code, error}}
    end
  end

  @doc """
  Returns a stable, credential-free fingerprint for a repository location.

  Equivalent HTTPS and SSH remote forms share an identity, while local paths
  are expanded before hashing. URLs containing query strings, fragments, or
  HTTP credentials are rejected so secret-bearing repository URLs cannot
  become runtime trust evidence.
  """
  @spec repository_fingerprint(String.t()) ::
          {:ok, String.t()} | {:error, :invalid_repo_url}
  def repository_fingerprint(repo_url) when is_binary(repo_url) do
    with {:ok, identity} <- normalize_repository_identity(repo_url) do
      fingerprint =
        :sha256
        |> :crypto.hash(identity)
        |> Base.encode16(case: :lower)

      {:ok, fingerprint}
    end
  end

  def repository_fingerprint(_repo_url), do: {:error, :invalid_repo_url}

  @doc """
  Resolves the repository URL for a project.

  Uses the project's canonical `repo_url` field, then the legacy `repo_url`
  setting, and finally the `:workspace_default_repo` application env. Returns
  `{:ok, url}` or `{:error, :no_repo_configured}`.
  """
  def get_repo_url(project_id) when is_binary(project_id) do
    case Cympho.Projects.get_project(project_id) do
      {:ok, %{repo_url: url}} when is_binary(url) and url != "" ->
        {:ok, url}

      {:ok, project} ->
        legacy_or_fallback_repo_url(project.settings)

      {:error, :not_found} ->
        fallback_repo_url()
    end
  end

  defp legacy_or_fallback_repo_url(%{"repo_url" => url})
       when is_binary(url) and url != "",
       do: {:ok, url}

  defp legacy_or_fallback_repo_url(_settings), do: fallback_repo_url()

  defp fallback_repo_url do
    case Application.get_env(:cympho, :workspace_default_repo) do
      nil -> {:error, :no_repo_configured}
      "" -> {:error, :no_repo_configured}
      url -> {:ok, url}
    end
  end

  defp normalize_repository_identity(repo_url) do
    repo_url = String.trim(repo_url)

    cond do
      repo_url == "" ->
        {:error, :invalid_repo_url}

      scp_repository_url?(repo_url) ->
        normalize_scp_repository_identity(repo_url)

      true ->
        normalize_uri_repository_identity(URI.parse(repo_url), repo_url)
    end
  end

  defp scp_repository_url?(repo_url) do
    not String.contains?(repo_url, "://") and
      String.match?(repo_url, ~r/\A(?:[^@\/:\s]+@)?[^\/:\s]+:[^?#\s]+\z/)
  end

  defp normalize_scp_repository_identity(repo_url) do
    case Regex.named_captures(
           ~r/\A(?:(?<user>[^@\/:\s]+)@)?(?<host>[^\/:\s]+):(?<path>[^?#\s]+)\z/,
           repo_url
         ) do
      %{"host" => host, "path" => path, "user" => user} ->
        normalize_remote_identity(host, nil, path, optional_capture(user))

      _captures ->
        {:error, :invalid_repo_url}
    end
  end

  defp normalize_uri_repository_identity(
         %URI{scheme: scheme, host: host, path: path, query: nil, fragment: nil} = uri,
         _repo_url
       )
       when scheme in ["git", "ssh"] and is_binary(host) and is_binary(path) do
    if valid_ssh_userinfo?(uri.userinfo) do
      normalize_remote_identity(host, non_default_port(uri), path, uri.userinfo)
    else
      {:error, :invalid_repo_url}
    end
  end

  defp normalize_uri_repository_identity(
         %URI{
           scheme: scheme,
           host: host,
           path: path,
           query: nil,
           fragment: nil,
           userinfo: nil
         } = uri,
         _repo_url
       )
       when scheme in ["http", "https"] and is_binary(host) and is_binary(path) do
    normalize_remote_identity(host, non_default_port(uri), path, nil)
  end

  defp normalize_uri_repository_identity(
         %URI{
           scheme: "file",
           host: host,
           path: path,
           query: nil,
           fragment: nil,
           userinfo: nil
         },
         _repo_url
       )
       when host in [nil, "", "localhost"] and is_binary(path) do
    normalize_local_identity(path)
  end

  defp normalize_uri_repository_identity(%URI{scheme: nil}, repo_url) do
    normalize_local_identity(repo_url)
  end

  defp normalize_uri_repository_identity(_uri, _repo_url), do: {:error, :invalid_repo_url}

  defp normalize_remote_identity(host, port, path, ssh_username) do
    path =
      path
      |> String.trim("/")
      |> String.replace(~r/\.git\z/i, "")

    cond do
      path == "" ->
        {:error, :invalid_repo_url}

      Enum.any?(String.split(path, "/"), &(&1 in ["", ".", ".."])) ->
        {:error, :invalid_repo_url}

      true ->
        authority =
          ssh_identity_prefix(ssh_username) <>
            String.downcase(host) <>
            if(port, do: ":#{port}", else: "")

        {:ok, "remote://#{authority}/#{path}"}
    end
  end

  defp normalize_local_identity(path) do
    path = String.trim(path)

    if path == "" do
      {:error, :invalid_repo_url}
    else
      {:ok, "local://#{Path.expand(path)}"}
    end
  end

  defp valid_ssh_userinfo?(nil), do: true

  defp valid_ssh_userinfo?(userinfo) do
    userinfo != "" and
      not String.contains?(userinfo, ":") and
      String.match?(userinfo, ~r/\A[^@\/:\s]+\z/)
  end

  defp optional_capture(""), do: nil
  defp optional_capture(value), do: value

  defp ssh_identity_prefix(username) when username in [nil, "git"], do: ""
  defp ssh_identity_prefix(username), do: "#{username}@"

  defp non_default_port(%URI{scheme: scheme, port: port}) do
    if port in [nil, URI.default_port(scheme)], do: nil, else: port
  end
end
