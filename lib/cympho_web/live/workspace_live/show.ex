defmodule CymphoWeb.WorkspaceLive.Show do
  use CymphoWeb, :live_view

  alias Cympho.{Workspace, Issues, Projects, Repo}

  @impl true
  def mount(%{"issue_id" => issue_id}, _session, socket) do
    case Issues.get_issue(issue_id) do
      {:ok, issue} ->
        issue = Repo.preload(issue, [:project, :assignee])

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

  defp apply_action(socket, nil, params), do: apply_action(socket, :show, params)

  @impl true
  def render(assigns) do
    ~H"""
    <.page size="wide">
      <.header
        title="Issue Workspace"
        subtitle="Repository state, prompt material, and local execution directory for this issue."
      >
        <:actions>
          <.app_link
            navigate={~p"/issues/#{@issue.id}"}
            class="rounded-lg border border-border bg-panel px-3 py-2 text-sm font-510 text-text-secondary hover:bg-surface-hover hover:text-text-primary"
          >
            Back to Issue
          </.app_link>
        </:actions>
      </.header>

      <div class="grid gap-4 xl:grid-cols-[minmax(0,1fr)_360px]">
        <.panel class="overflow-hidden">
          <div class="border-b border-border px-5 py-4">
            <div class="flex flex-wrap items-center gap-2 text-xs text-text-tertiary">
              <span class="font-mono">{@issue.identifier || String.slice(@issue.id, 0, 8)}</span>
              <span class="h-1 w-1 rounded-full bg-border-strong"></span>
              <span class="capitalize">{String.replace(to_string(@issue.status), "_", " ")}</span>
              <span class="h-1 w-1 rounded-full bg-border-strong"></span>
              <span class="capitalize">{@issue.priority}</span>
            </div>
            <h2 class="mt-2 text-lg font-590 leading-6 text-text-primary">{@issue.title}</h2>
            <p :if={@issue.description not in [nil, ""]} class="mt-2 max-w-3xl text-sm leading-6 text-text-secondary">
              {@issue.description}
            </p>
          </div>

          <div class="grid gap-px bg-border md:grid-cols-3">
            <div class="bg-panel px-5 py-4">
              <p class="text-xs font-510 uppercase tracking-wide text-text-tertiary">Workspace</p>
              <p class="mt-2 text-sm font-510 text-text-primary">
                <%= if @workspace_exists, do: "Ready", else: "Not created" %>
              </p>
            </div>
            <div class="bg-panel px-5 py-4">
              <p class="text-xs font-510 uppercase tracking-wide text-text-tertiary">Project</p>
              <p class="mt-2 truncate text-sm font-510 text-text-primary">
                <%= if @project, do: @project.name, else: "No project" %>
              </p>
            </div>
            <div class="bg-panel px-5 py-4">
              <p class="text-xs font-510 uppercase tracking-wide text-text-tertiary">Assignee</p>
              <p class="mt-2 truncate text-sm font-510 text-text-primary">
                <%= if @issue.assignee, do: @issue.assignee.name, else: "Unassigned" %>
              </p>
            </div>
          </div>

          <div class="space-y-4 p-5">
            <div>
              <p class="mb-2 text-xs font-510 uppercase tracking-wide text-text-tertiary">Path</p>
              <code class="block overflow-x-auto rounded-lg border border-border bg-surface px-3 py-2 text-xs text-text-secondary">
                {@workspace_path}
              </code>
            </div>

            <div>
              <p class="mb-2 text-xs font-510 uppercase tracking-wide text-text-tertiary">Repository</p>
              <p class="rounded-lg border border-border bg-surface px-3 py-2 text-sm text-text-secondary">
                {@repo_url || "No repository configured for this project."}
              </p>
            </div>

            <.simple_form
              :if={@workspace_exists}
              for={%{}}
              as={:prompt}
              phx-submit="write_prompt"
              class="space-y-3"
            >
              <.input
                name="prompt"
                value=""
                label="Prompt File"
                type="textarea"
                rows={6}
                placeholder="Write a short execution brief to PROMPT.md"
              />
              <:actions>
                <div class="flex justify-end">
                  <.button type="submit" variant="secondary">Write PROMPT.md</.button>
                </div>
              </:actions>
            </.simple_form>
          </div>
        </.panel>

        <div class="space-y-4">
          <.panel class="p-5">
            <h3 class="text-sm font-590 text-text-primary">Workspace Controls</h3>
            <p class="mt-2 text-sm leading-6 text-text-secondary">
              Create the local directory once a repository is configured. Removing it clears the local issue workspace.
            </p>
            <div class="mt-4 flex flex-col gap-2">
              <.button
                :if={!@workspace_exists}
                type="button"
                variant="primary"
                phx-click="create_workspace"
                disabled={is_nil(@repo_url)}
              >
                Create Workspace
              </.button>
              <.button
                :if={@workspace_exists}
                type="button"
                variant="secondary"
                phx-click="delete_workspace"
                data-confirm="Delete this local workspace directory?"
              >
                Delete Workspace
              </.button>
            </div>
          </.panel>

          <.panel class="p-5">
            <h3 class="text-sm font-590 text-text-primary">Details</h3>
            <dl class="mt-4 space-y-3 text-sm">
              <div class="flex justify-between gap-4">
                <dt class="text-text-tertiary">Size</dt>
                <dd class="text-text-secondary">
                  <%= if @workspace_exists, do: format_workspace_size(@workspace_path), else: "N/A" %>
                </dd>
              </div>
              <div class="flex justify-between gap-4">
                <dt class="text-text-tertiary">Issue ID</dt>
                <dd class="font-mono text-xs text-text-secondary">{String.slice(@issue.id, 0, 8)}</dd>
              </div>
            </dl>
          </.panel>
        </div>
      </div>
    </.page>
    """
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
