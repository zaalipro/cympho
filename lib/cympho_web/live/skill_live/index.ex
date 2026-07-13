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

  attr :enabled, :boolean, required: true

  def skill_state(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1.5 text-xs font-510",
      (@enabled && "text-text-tertiary") || "text-text-quaternary"
    ]}>
      <span class={[
        "h-1.5 w-1.5 rounded-full",
        (@enabled && "bg-emerald-400/80") || "bg-text-quaternary/60"
      ]}>
      </span>
      {(@enabled && "Enabled") || "Disabled"}
    </span>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :tone, :atom, default: :neutral

  def skill_health_metric(assigns) do
    ~H"""
    <div class="bg-surface/70 px-3 py-2 text-center">
      <p class={"font-mono text-[18px] font-590 leading-none #{skill_metric_text(@tone)}"}>
        {@value}
      </p>
      <p class="mt-1 text-[10px] uppercase tracking-[0.12em] text-text-quaternary">
        {@label}
      </p>
    </div>
    """
  end

  def skill_health_badge(:critical), do: "border-red-500/25 bg-red-500/10 text-red-300"
  def skill_health_badge(:warning), do: "border-amber-500/25 bg-amber-500/10 text-amber-300"

  def skill_health_badge(:healthy),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"

  def skill_health_badge(:empty), do: "border-border bg-surface text-text-tertiary"
  def skill_health_badge(_), do: "border-border bg-surface text-text-tertiary"

  def skill_metric_text(:critical), do: "text-red-300"
  def skill_metric_text(:warning), do: "text-amber-300"
  def skill_metric_text(:ok), do: "text-emerald-300"
  def skill_metric_text(_), do: "text-text-primary"

  def skill_recommendation_class(:critical), do: "border-red-500/20 bg-red-500/10 text-red-100"

  def skill_recommendation_class(:warning),
    do: "border-amber-500/20 bg-amber-500/10 text-amber-100"

  def skill_recommendation_class(_), do: "border-border bg-surface text-text-secondary"

  def skill_next_action_class(:critical), do: "border-red-500/25 bg-red-500/10 text-red-100"
  def skill_next_action_class(:warning), do: "border-amber-500/25 bg-amber-500/10 text-amber-100"

  def skill_next_action_class(:ok),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-100"

  def skill_next_action_class(_), do: "border-border bg-surface text-text-secondary"

  def skill_posture_label(:empty), do: "Setup posture"
  def skill_posture_label(_level), do: "Capability posture"

  def skill_posture_text(:empty) do
    "No reusable skills exist for this company. Add one narrow skill with a valid manifest before broadening agent capability access."
  end

  def skill_posture_text(_level) do
    "Skill manifests, capabilities, and hot reload are ready for runtime use."
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
    "Create one narrow capability with a valid manifest, assign it only where agents can produce evidence, then watch health here."
  end

  def skill_empty_action_class(:primary) do
    "inline-flex h-8 items-center justify-center rounded-lg bg-primary px-3 text-xs font-510 text-white transition-colors hover:bg-primary-hover"
  end

  def skill_empty_action_class(_tone) do
    "inline-flex h-8 items-center justify-center rounded-lg border border-border bg-surface px-3 text-xs font-510 text-text-secondary transition-colors hover:bg-surface-hover hover:text-text-primary"
  end

  def scope_label(%{company: %{name: name}}) when is_binary(name), do: name
  def scope_label(_skill), do: "Global"

  def manifest_entrypoint(%{manifest: manifest}) when is_map(manifest) do
    Map.get(manifest, "entrypoint") || Map.get(manifest, :entrypoint) || "No entrypoint"
  end

  def manifest_entrypoint(_skill), do: "No entrypoint"

  def capability_count(%{manifest: manifest}) when is_map(manifest) do
    case Map.get(manifest, "capabilities") || Map.get(manifest, :capabilities) do
      capabilities when is_list(capabilities) -> length(capabilities)
      _ -> 0
    end
  end

  def capability_count(_skill), do: 0

  def skill_manifest_gap?(skill), do: not valid_manifest?(skill)

  defp valid_manifest?(%{manifest: manifest}) do
    match?({:ok, _}, Cympho.Skills.Manifest.validate(manifest))
  end
end
