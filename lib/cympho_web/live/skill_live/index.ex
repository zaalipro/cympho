defmodule CymphoWeb.SkillLive.Index do
  use CymphoWeb, :live_view

  alias Cympho.Skills

  @impl true
  def mount(_params, _session, socket) do
    companies = user_companies(socket)
    selected_company_id = default_company_id(socket, companies)

    {:ok,
     socket
     |> assign(:companies, companies)
     |> assign(:selected_company_id, selected_company_id)
     |> assign(:selected_project_id, nil)
     |> assign(:skill_health, Skills.health_summary(selected_company_id))
     |> assign(:infinite_scroll, %{})
     |> assign(:page_title, "Skills")}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, params) do
    company_id =
      normalize_company_filter(
        params["company_id"],
        socket.assigns.companies,
        default_company_id(socket, socket.assigns.companies)
      )

    socket =
      socket
      |> assign(:page_title, "Skills")
      |> assign(:skill, nil)
      |> assign(:selected_company_id, company_id)
      |> assign(:skill_health, Skills.health_summary(company_id))

    init_stream(socket, :skill, &fetch_skills(socket, &1))
  end

  defp apply_action(socket, nil, params) do
    apply_action(socket, :index, params)
  end

  @impl true
  def handle_event("filter_company", %{"company_id" => company_id}, socket) do
    company_id =
      normalize_company_filter(
        company_id,
        socket.assigns.companies,
        socket.assigns[:selected_company_id]
      )

    socket =
      socket
      |> assign(:selected_company_id, company_id)
      |> assign(:selected_project_id, nil)
      |> assign(:skill_health, Skills.health_summary(company_id))

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
             |> refresh_skill_health()
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
             |> refresh_skill_health()
             |> put_flash(:info, "Skill deleted successfully")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete skill")}
        end

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Skill not found")}
    end
  end

  defp fetch_skills(socket, cursor) do
    case socket.assigns[:selected_company_id] do
      nil ->
        %Cympho.Pagination.Page{entries: [], next_cursor: nil, has_more?: false}

      company_id ->
        Skills.list_skills_page(
          company_id: company_id,
          project_id: socket.assigns[:selected_project_id],
          after: cursor
        )
    end
  end

  defp fetch_company_skill(socket, id) do
    case socket.assigns[:current_company] do
      %{id: company_id} -> Skills.get_company_skill(company_id, id)
      _ -> {:error, :not_found}
    end
  end

  defp refresh_skill_health(socket) do
    assign(socket, :skill_health, Skills.health_summary(socket.assigns[:selected_company_id]))
  end

  defp user_companies(socket) do
    case socket.assigns[:user_companies] do
      companies when is_list(companies) and companies != [] ->
        companies

      _ ->
        case socket.assigns[:current_company] do
          nil -> []
          company -> [company]
        end
    end
  end

  defp default_company_id(socket, companies) do
    current_company_id(socket) || first_company_id(companies)
  end

  defp current_company_id(%{assigns: %{current_company: %{id: id}}}), do: id
  defp current_company_id(_socket), do: nil

  defp first_company_id([%{id: id} | _]), do: id
  defp first_company_id(_companies), do: nil

  defp normalize_company_filter(company_id, companies, default_id) when is_binary(company_id) do
    company_id = String.trim(company_id)

    cond do
      Enum.any?(companies, &(&1.id == company_id)) -> company_id
      Enum.any?(companies, &(&1.id == default_id)) -> default_id
      true -> first_company_id(companies)
    end
  end

  defp normalize_company_filter(_company_id, companies, default_id) do
    if Enum.any?(companies, &(&1.id == default_id)),
      do: default_id,
      else: first_company_id(companies)
  end

  def skill_next_action_path(%{key: :create_first_skill}), do: "/skills/new"

  def skill_next_action_path(%{key: :start_hot_reloader}),
    do: "/operations#runtime-launch-checklist"

  def skill_next_action_path(_action), do: "/skills"

  def skill_empty_title(nil), do: "No company selected for skills"
  def skill_empty_title(_company_id), do: "No reusable skills configured yet"

  def skill_empty_detail(nil) do
    "Select a company before creating reusable capabilities for agents."
  end

  def skill_empty_detail(_company_id) do
    "Add one skill and assign it to the agents that need it."
  end

  def skill_manifest_gap?(skill), do: not valid_manifest?(skill)

  defp valid_manifest?(%{manifest: manifest}) do
    match?({:ok, _}, Cympho.Skills.Manifest.validate(manifest))
  end
end
