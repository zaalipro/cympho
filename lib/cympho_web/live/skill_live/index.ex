defmodule CymphoWeb.SkillLive.Index do
  use CymphoWeb, :live_view

  alias Cympho.{Skills, Companies}

  @impl true
  def mount(_params, _session, socket) do
    companies = Companies.list_companies()

    {:ok,
     socket
     |> assign(:companies, companies)
     |> assign(:selected_company_id, nil)
     |> assign(:selected_project_id, nil)
     |> assign(:infinite_scroll, %{})
     |> assign(:page_title, "Skills")}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Skills")
    |> assign(:skill, nil)
    |> init_stream(:skill, &fetch_skills(socket, &1))
  end

  defp apply_action(socket, nil, params) do
    apply_action(socket, :index, params)
  end

  @impl true
  def handle_event("filter_company", %{"company_id" => company_id}, socket) do
    company_id = if company_id == "", do: nil, else: company_id

    socket =
      socket
      |> assign(:selected_company_id, company_id)
      |> assign(:selected_project_id, nil)

    {:noreply, reset_stream(socket, :skill, &fetch_skills(socket, &1))}
  end

  @impl true
  def handle_event("next-page", _params, socket) do
    {:reply, %{}, load_next(socket, :skill, &fetch_skills(socket, &1))}
  end

  @impl true
  def handle_event("toggle_skill", %{"id" => id}, socket) do
    case fetch_company_skill(socket, id) do
      {:ok, skill} ->
        case Skills.toggle_skill(skill) do
          {:ok, updated_skill} ->
            updated_skill = Cympho.Repo.preload(updated_skill, [:company, :project])

            {:noreply,
             socket
             |> stream_insert(:skill, updated_skill)
             |> put_flash(
               :info,
               "Skill #{if updated_skill.enabled, do: "enabled", else: "disabled"}"
             )}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to toggle skill")}
        end

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Skill not found")}
    end
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    case fetch_company_skill(socket, id) do
      {:ok, skill} ->
        case Skills.delete_skill(skill) do
          {:ok, _} ->
            {:noreply,
             socket
             |> stream_delete(:skill, skill)
             |> put_flash(:info, "Skill deleted successfully")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete skill")}
        end

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Skill not found")}
    end
  end

  defp fetch_skills(socket, cursor) do
    Skills.list_skills_page(
      company_id: socket.assigns[:selected_company_id],
      project_id: socket.assigns[:selected_project_id],
      after: cursor
    )
  end

  defp fetch_company_skill(socket, id) do
    case socket.assigns[:current_company] do
      %{id: company_id} -> Skills.get_company_skill(company_id, id)
      _ -> {:error, :not_found}
    end
  end
end
