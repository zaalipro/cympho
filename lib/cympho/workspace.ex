defmodule Cympho.Workspace do
  @moduledoc """
  The Workspace context manages per-issue working directories.

  Each issue gets its own git-cloned workspace under a configurable root,
  allowing isolated agent work without conflicts.
  """

  @workspace_root Application.compile_env(:cympho, :workspace_root, "/tmp/cympho/workspaces")

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
  def create_for_issue(%{id: issue_id, project_id: project_id}) do
    path = workspace_path(issue_id)

    with :ok <- ensure_root_exists(),
         :ok <- validate_path_is_safe(path),
         {:ok, _} <- clone_repo(project_id, path) do
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
    # TODO: Look up repo URL from project_id when project repository is available
    # For now, this is a placeholder that can be replaced with actual repo cloning
    repo_url = get_repo_url(project_id)

    System.cmd("git", ["clone", "--quiet", repo_url, path])
    |> case do
      {_output, 0} -> {:ok, path}
      {error, exit_code} -> {:error, {:git_clone_failed, exit_code, error}}
    end
  end

  defp get_repo_url(_project_id) do
    # Placeholder: in production, look up the project's repo URL from the database
    # For now, return an empty repo or the configured default
    Application.get_env(:cympho, :workspace_default_repo, "")
  end
end
