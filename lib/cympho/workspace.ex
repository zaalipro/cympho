defmodule Cympho.Workspace do
  @moduledoc """
  The Workspace context manages per-issue working directories.

  Each issue gets its own git-cloned workspace under a configurable root,
  allowing isolated agent work without conflicts.
  """

  @workspace_root Application.compile_env(:cympho, :workspace_root, "/tmp/cympho/workspaces")

  alias Cympho.PullRequestContract

  @doc """
  Returns the workspace root directory.
  """
  def workspace_root, do: @workspace_root

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

  defp checkout_issue_branch(path, issue) do
    branch_name = PullRequestContract.branch_name(issue)

    case System.cmd("git", ["checkout", "-B", branch_name], cd: path) do
      {_output, 0} -> {:ok, branch_name}
      {error, exit_code} -> {:error, {:git_checkout_failed, exit_code, error}}
    end
  end

  @doc """
  Resolves the repository URL for a project.

  Looks up the project's settings map for a `repo_url` key, falling back to
  the `:workspace_default_repo` application env. Returns `{:ok, url}` or
  `{:error, :no_repo_configured}`.
  """
  def get_repo_url(project_id) when is_binary(project_id) do
    case Cympho.Projects.get_project(project_id) do
      {:ok, project} ->
        case project.settings do
          %{"repo_url" => url} when is_binary(url) and url != "" ->
            {:ok, url}

          _ ->
            fallback_repo_url()
        end

      {:error, :not_found} ->
        fallback_repo_url()
    end
  end

  defp fallback_repo_url do
    case Application.get_env(:cympho, :workspace_default_repo) do
      nil -> {:error, :no_repo_configured}
      "" -> {:error, :no_repo_configured}
      url -> {:ok, url}
    end
  end
end
