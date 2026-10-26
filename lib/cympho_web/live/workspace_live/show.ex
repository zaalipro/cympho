defmodule CymphoWeb.WorkspaceLive.Show do
  use CymphoWeb, :live_view

  alias Cympho.{Workspace, Issues, Projects, Repo}

  @impl true
  def mount(%{"issue_id" => issue_id}, _session, socket) do
    company = socket.assigns[:current_company]

    case fetch_company_issue(company, issue_id) do
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
          case Projects.get_company_project(company.id, issue.project_id) do
            {:ok, p} -> p
            {:error, _} -> nil
          end

        {:ok,
         socket
         |> assign(:page_title, "Work files for #{task_label(issue)}")
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

  defp fetch_company_issue(%{id: company_id}, issue_id),
    do: Issues.get_company_issue(company_id, issue_id)

  defp fetch_company_issue(_, _), do: {:error, :not_found}

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :show, _params) do
    socket
    |> assign(:page_title, "Work files for #{task_label(socket.assigns.issue)}")
  end

  defp apply_action(socket, nil, params), do: apply_action(socket, :show, params)

  @impl true
  def render(assigns) do
    ~H"""
    <.page_frame
      page="issue-workfile"
      kind={:deep}
      parent={{~p"/issues/#{@issue.id}", task_label(@issue)}}
      current="Work files"
      data-ui-complex-page
    >
      <:head>
        <section class="head" aria-labelledby="iw-h">
          <h1 class="h1 big" id="iw-h">Work files for {task_label(@issue)}</h1>
          <p class="sub">{@issue.title}</p>
          <.flash_line flash={@flash} />
        </section>
      </:head>

      <.band_card :if={!@workspace_exists} id="iw-t" title="Work folder">
        <.quiet_empty title="No work folder yet">
          {if @repo_url,
            do: "Creates a local copy of #{@repo_url} on a branch for this task.",
            else:
              "Add a repository to #{if @project, do: @project.name, else: "the task's project"} first; the folder is copied from it."}
          <:action>
            <.pill phx-click="create_workspace" disabled={is_nil(@repo_url)}>
              Create work folder
            </.pill>
          </:action>
        </.quiet_empty>
      </.band_card>

      <.band_card :if={@workspace_exists} id="iw-t" title="Work folder">
        <.kv_list class="wide">
          <:item term="Path"><span class="mono iw-path">{@workspace_path}</span></:item>
          <:item term="Repository">
            <span class={["iw-path", @repo_url && "mono"]}>
              {@repo_url || "No repository configured for this project."}
            </span>
          </:item>
          <:item term="Size">
            <span class="mono">{format_workspace_size(@workspace_path)}</span>
          </:item>
        </.kv_list>
      </.band_card>

      <.band_card :if={@workspace_exists} id="iw-prompt-t" title="Brief for the agent">
        <form id="iw-prompt" class="iw-form" phx-submit="write_prompt">
          <.input
            id="iw-prompt-body"
            name="prompt"
            value=""
            label="PROMPT.md"
            type="textarea"
            rows={6}
            placeholder="Write a short execution brief to PROMPT.md"
          />
          <div class="iw-f">
            <p class="help">Saves PROMPT.md in the folder, replacing the one there.</p>
            <.pill type="submit">Write PROMPT.md</.pill>
          </div>
        </form>
      </.band_card>

      <div :if={@workspace_exists} class="card">
        <ul class="rows">
          <.list_row id="iw-delete" title="Delete work folder">
            <:meta>Removes the local folder for this task. The repository is not touched.</:meta>
            <:actions>
              <button
                type="button"
                class="pl warn"
                phx-click="delete_workspace"
                data-confirm="Delete this local workspace directory?"
              >
                Delete
              </button>
            </:actions>
          </.list_row>
        </ul>
      </div>
    </.page_frame>
    """
  end

  defp task_label(issue), do: issue.identifier || String.slice(issue.id, 0, 8)

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
