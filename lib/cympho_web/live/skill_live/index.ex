defmodule CymphoWeb.SkillLive.Index do
  use CymphoWeb, :live_view

  alias Cympho.{Skills, Companies, Repo}

  @impl true
  def mount(_params, _session, socket) do
    companies = Companies.list_companies()

    {:ok,
     socket
     |> assign(:skills, [])
     |> assign(:companies, companies)
     |> assign(:selected_company_id, nil)
     |> assign(:selected_project_id, nil)
     |> assign(:page_title, "Skills")}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    skills = list_skills_for_filters(socket)

    socket
    |> assign(:page_title, "Skills")
    |> assign(:skill, nil)
    |> assign(:skills, skills)
  end

  defp apply_action(socket, nil, params) do
    apply_action(socket, :index, params)
  end

  @impl true
  def handle_event("filter_company", %{"company_id" => company_id}, socket) do
    company_id = if company_id == "", do: nil, else: company_id

    skills = list_skills_for_filters(socket, company_id, nil)

    {:noreply,
     socket
     |> assign(:selected_company_id, company_id)
     |> assign(:selected_project_id, nil)
     |> assign(:skills, skills)}
  end

  @impl true
  def handle_event("toggle_skill", %{"id" => id}, socket) do
    case Skills.get_skill(id) do
      {:ok, skill} ->
        case Skills.toggle_skill(skill) do
          {:ok, updated_skill} ->
            {:noreply,
             socket
             |> update(:skills, fn skills ->
               Enum.map(skills, fn s ->
                 if s.id == updated_skill.id, do: updated_skill, else: s
               end)
             end)
             |> put_flash(:info, "Skill #{if updated_skill.enabled, do: "enabled", else: "disabled"}")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to toggle skill")}
        end

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Skill not found")}
    end
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    case Skills.get_skill(id) do
      {:ok, skill} ->
        case Skills.delete_skill(skill) do
          {:ok, _} ->
            {:noreply,
             socket
             |> update(:skills, fn skills -> Enum.filter(skills, &(&1.id != id)) end)
             |> put_flash(:info, "Skill deleted successfully")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete skill")}
        end

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Skill not found")}
    end
  end

  defp list_skills_for_filters(socket, company_id \\ nil, project_id \\ nil) do
    company_id = company_id || socket.assigns[:selected_company_id]

    Skills.list_skills(company_id: company_id, project_id: project_id)
    |> Enum.map(fn s -> Repo.preload(s, [:company, :project]) end)
  end
end

