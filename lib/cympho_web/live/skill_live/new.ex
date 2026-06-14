defmodule CymphoWeb.SkillLive.New do
  use CymphoWeb, :live_view

  alias Cympho.Skills
  alias CymphoWeb.SkillLive.FormHelpers

  @impl true
  def mount(_params, _session, socket) do
    changeset = Skills.change_skill(%Skills.Skill{})

    {:ok,
     socket
     |> assign(:page_title, "New Skill")
     |> assign(:skill, %Skills.Skill{})
     |> FormHelpers.assign_context_options()
     |> assign_form(changeset)}
  end

  @impl true
  def handle_event("save", %{"skill" => skill_params}, socket) do
    with {:ok, skill_params} <-
           FormHelpers.normalize_skill_params(socket, skill_params, put_company_scope: true) do
      case Skills.create_skill(skill_params) do
        {:ok, skill} ->
          {:noreply,
           socket
           |> put_flash(:info, "Skill created successfully")
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
    case FormHelpers.normalize_skill_params(socket, skill_params, put_company_scope: true) do
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
