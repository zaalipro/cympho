defmodule CymphoWeb.SkillLive.FormComponent do
  use CymphoWeb, :live_component

  alias Cympho.Skills
  alias Cympho.Companies

  @impl true
  def update(%{skill: skill} = assigns, socket) do
    changeset = Skills.change_skill(skill)

    companies = Companies.list_companies()

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:companies, companies)
     |> assign_form(changeset)}
  end

  @impl true
  def handle_event("validate", %{"skill" => skill_params}, socket) do
    changeset =
      socket.assigns.skill
      |> Skills.change_skill(skill_params)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"skill" => skill_params}, socket) do
    save_skill(socket, socket.assigns.action, skill_params)
  end

  defp save_skill(socket, :edit, skill_params) do
    case Skills.update_skill(socket.assigns.skill, skill_params) do
      {:ok, skill} ->
        {:noreply,
         socket
         |> put_flash(:info, "Skill updated successfully")
         |> push_navigate(to: ~p"/skills/#{skill}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp save_skill(socket, :new, skill_params) do
    case Skills.create_skill(skill_params) do
      {:ok, skill} ->
        {:noreply,
         socket
         |> put_flash(:info, "Skill created successfully")
         |> push_navigate(to: ~p"/skills/#{skill}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, :form, to_form(changeset))
  end
end
