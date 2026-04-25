defmodule CymphoWeb.WorkspaceLive.Show do
  use CymphoWeb, :live_view

  alias Cympho.{Workspace, Issues, Projects, Agents, Repo}

  @impl true
  def mount(%{"issue_id" => issue_id}, _session, socket) do
    case Issues.get_issue(issue_id) do
      {:ok, issue} ->
        issue = Repo.preload(issue, [:project, :agent])

        workspace_path = Workspace.workspace_path(issue)
        workspace_exists = File.dir?(workspace_path)

        repo_url =
          case Workspace.get_repo_url(issue.project_id) do
            {:ok, url} -> url
            {:error, _} -> nil
          end

        project =
          case Projects.get_project(issue.project_id) do
            {:ok, p} -> p
            {:error, _} -> nil
          end

        {:ok,
         socket
         |> assign(:page_title, "Workspace: #{issue.id}")
         |> assign(:issue, issue)
         |> assign(:workspace_path, workspace_path)
         |> assign(:workspace_exists, workspace_exists)
         |> assign(:repo_url, repo_url)
         |> assign(:project, project)}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Issue not found")
         |> push_navigate(to: ~p"/issues")}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :show, _params) do
    socket
    |> assign(:page_title, "Workspace: #{socket.assigns.issue.id}")
  end

  @impl true
  def handle_event("create_workspace", _params, socket) do
    case Workspace.create_for_issue(socket.assigns.issue) do
      {:ok, path} ->
        {:noreply,
         socket
         |> assign(:workspace_path, path)
         |> assign(:workspace_exists, true)
         |> put_flash(:info, "Workspace created successfully")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to create workspace: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("delete_workspace", _params, socket) do
    case Workspace.remove_issue_workspaces(socket.assigns.issue) do
      :ok ->
        {:noreply,
         socket
         |> assign(:workspace_exists, false)
         |> put_flash(:info, "Workspace deleted successfully")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to delete workspace: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("write_prompt", %{"prompt" => prompt}, socket) do
    if socket.assigns.workspace_exists do
      case Workspace.write_prompt_file(socket.assigns.workspace_path, prompt) do
        :ok ->
          {:noreply, put_flash(socket, :info, "Prompt file written successfully")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to write prompt: #{inspect(reason)}")}
      end
    else
      {:noreply, put_flash(socket, :error, "Workspace does not exist")}
    end
  end

  def format_workspace_size(path) do
    case File.ls(path) do
      {:ok, files} ->
        total_bytes =
          Enum.reduce(files, 0, fn file, acc ->
            full_path = Path.join(path, file)
            case File.stat(full_path) do
              {:ok, stat} -> acc + stat.size
              _ -> acc
            end
          end)

        format_bytes(total_bytes)

      _ ->
        "N/A"
    end
  end

  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1024 * 1024, do: "#{div(bytes, 1024)} KB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / (1024 * 1024), 2)} MB"
end
