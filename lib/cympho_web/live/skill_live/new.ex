defmodule CymphoWeb.SkillLive.New do
  use CymphoWeb, :live_view

  alias Cympho.Skills

  @impl true
  def mount(_params, _session, socket) do
    changeset = Skills.change_skill(%Skills.Skill{})

    {:ok,
     socket
     |> assign(:page_title, "New Skill")
     |> assign(:skill, %Skills.Skill{})
     |> assign_form(changeset)}
  end

  @impl true
  def handle_event("save", %{"skill" => skill_params}, socket) do
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

  def handle_event("validate", %{"skill" => skill_params}, socket) do
    changeset =
      socket.assigns.skill
      |> Skills.change_skill(skill_params)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, :form, to_form(changeset))
  end
end
