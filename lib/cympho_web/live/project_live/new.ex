defmodule CymphoWeb.ProjectLive.New do
  use CymphoWeb, :live_view
  alias Cympho.Projects
  alias Cympho.Projects.Project

  @impl true
  def mount(_params, _session, socket) do
    scope = project_scope(socket)
    changeset = Projects.change_project(%Project{}, scope)

    {:ok,
     socket
     |> assign(:project_scope, scope)
     |> assign(:form, to_form(changeset))}
  end

  @impl true
  def handle_event("save", %{"project" => project_params}, socket) do
    # The browser form never needs to choose its tenant. Keep the selected
    # company authoritative even when a client forges an extra company_id.
    params = Map.merge(project_params, socket.assigns.project_scope)

    case Projects.create_project(params) do
      {:ok, project} ->
        {:noreply,
         socket
         |> put_flash(:info, "Project created. Add its first issue when you are ready.")
         |> push_navigate(to: ~p"/projects/#{project.id}")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp project_scope(socket) do
    case socket.assigns[:current_company] do
      %{id: company_id} -> %{"company_id" => company_id}
      _ -> %{}
    end
  end
end
