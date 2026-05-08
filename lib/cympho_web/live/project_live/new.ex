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
    params = Map.merge(socket.assigns.project_scope, project_params)

    case Projects.create_project(params) do
      {:ok, _project} ->
        {:noreply, push_navigate(socket, to: ~p"/projects")}

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
