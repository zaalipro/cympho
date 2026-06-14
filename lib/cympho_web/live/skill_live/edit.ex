defmodule CymphoWeb.SkillLive.Edit do
  use CymphoWeb, :live_view

  alias Cympho.Skills
  alias Cympho.Repo
  alias CymphoWeb.SkillLive.FormHelpers

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case fetch_company_skill(socket, id) do
      {:ok, skill} ->
        skill = Repo.preload(skill, [:company, :project])
        changeset = Skills.change_skill(skill)

        {:ok,
         socket
         |> assign(:page_title, "Edit #{skill.name}")
         |> assign(:skill, skill)
         |> FormHelpers.assign_context_options()
         |> assign_form(changeset)}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Skill not found")
         |> push_navigate(to: ~p"/skills")}
    end
  end

  defp fetch_company_skill(socket, id) do
    case socket.assigns[:current_company] do
      %{id: company_id} -> Skills.get_company_skill(company_id, id)
      _ -> {:error, :not_found}
    end
  end

  @impl true
  def handle_event("save", %{"skill" => skill_params}, socket) do
    with {:ok, skill_params} <-
           FormHelpers.normalize_skill_params(socket, skill_params, skill: socket.assigns.skill) do
      case Skills.update_skill(socket.assigns.skill, skill_params) do
        {:ok, skill} ->
          {:noreply,
           socket
           |> put_flash(:info, "Skill updated successfully")
           |> push_navigate(to: ~p"/skills/#{skill}")}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply, assign_form(socket, changeset)}
      end
    else
      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Choose a project from this company.")}
    end
  end

  def handle_event("validate", %{"skill" => skill_params}, socket) do
    case FormHelpers.normalize_skill_params(socket, skill_params, skill: socket.assigns.skill) do
      {:ok, skill_params} ->
        changeset =
          socket.assigns.skill
          |> Skills.change_skill(skill_params)
          |> Map.put(:action, :validate)

        {:noreply, assign_form(socket, changeset)}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Choose a project from this company.")}
    end
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, :form, to_form(changeset))
  end
end
