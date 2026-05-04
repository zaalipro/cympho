defmodule CymphoWeb.ProjectLive.Edit do
  use CymphoWeb, :live_view
  alias Cympho.{Projects, Secrets}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    project = Projects.get_project!(id)

    {:ok,
     socket
     |> assign(:project, project)
     |> assign(:form, to_form(Projects.change_project(project)))
     |> assign(:env_form, to_form(%{"key" => "", "value" => ""}, as: :env))
     |> assign(:secrets, list_project_secrets(project))}
  end

  @impl true
  def handle_event("save", %{"project" => project_params}, socket) do
    case Projects.update_project(socket.assigns.project, project_params) do
      {:ok, project} ->
        {:noreply,
         socket
         |> assign(:project, project)
         |> assign(:form, to_form(Projects.change_project(project)))
         |> put_flash(:info, "Project updated")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  def handle_event("add_env", %{"env" => %{"key" => key, "value" => value}}, socket) do
    project = socket.assigns.project
    key = key |> to_string() |> String.trim() |> String.upcase()

    cond do
      key == "" or value in [nil, ""] ->
        {:noreply, put_flash(socket, :error, "Key and value are required")}

      not String.match?(key, ~r/^[A-Z][A-Z0-9_]*$/) ->
        {:noreply, put_flash(socket, :error, "Key must be uppercase letters, digits, underscores")}

      project.company_id == nil ->
        {:noreply, put_flash(socket, :error, "Project missing company — cannot store secrets")}

      true ->
        attrs = %{
          company_id: project.company_id,
          scope: "project",
          scope_id: project.id,
          key: key,
          value: value,
          description: "Project env var"
        }

        case Secrets.create_secret(attrs) do
          {:ok, _secret} ->
            {:noreply,
             socket
             |> assign(:secrets, list_project_secrets(project))
             |> assign(:env_form, to_form(%{"key" => "", "value" => ""}, as: :env))
             |> put_flash(:info, "Added #{key}")}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Could not save env var")}
        end
    end
  end

  def handle_event("delete_env", %{"id" => id}, socket) do
    case Secrets.get_secret(id) do
      {:ok, secret} ->
        {:ok, _} = Secrets.delete_secret(secret)

        {:noreply,
         socket
         |> assign(:secrets, list_project_secrets(socket.assigns.project))
         |> put_flash(:info, "Removed #{secret.key}")}

      _ ->
        {:noreply, socket}
    end
  end

  defp list_project_secrets(%{id: id, company_id: company_id}) when is_binary(company_id) do
    Secrets.list_secrets(company_id, scope: "project", scope_id: id)
  end

  defp list_project_secrets(_), do: []
end
