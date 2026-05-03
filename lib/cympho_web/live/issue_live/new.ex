defmodule CymphoWeb.IssueLive.New do
  use CymphoWeb, :live_view
  alias Cympho.Issues
  alias Cympho.Issues.Issue
  alias Cympho.Projects

  @impl true
  def mount(_params, _session, socket) do
    changeset = Issues.change_issue(%Issue{})
    {:ok, assign(socket, form: to_form(changeset))}
  end

  @impl true
  def handle_event("save", %{"issue" => issue_params}, socket) do
    case Issues.create_issue(Map.merge(issue_params, issue_scope(socket))) do
      {:ok, _issue} ->
        {:noreply, push_navigate(socket, to: ~p"/issues")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp issue_scope(socket) do
    case socket.assigns[:current_company] do
      %{id: company_id} ->
        project_id =
          company_id
          |> Projects.list_projects_by_company()
          |> List.first()
          |> case do
            nil -> nil
            project -> project.id
          end

        attrs = %{"company_id" => company_id, "project_id" => project_id}

        case socket.assigns[:current_user] do
          %{id: user_id} -> Map.put(attrs, "created_by_user_id", user_id)
          _ -> attrs
        end

      _ ->
        %{}
    end
  end
end
