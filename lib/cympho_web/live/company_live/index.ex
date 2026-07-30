defmodule CymphoWeb.CompanyLive.Index do
  use CymphoWeb, :live_view

  alias Cympho.Companies

  @impl true
  def mount(_params, _session, socket) do
    blueprints = Companies.autonomous_company_blueprints()
    user_id = socket.assigns.current_user.id

    {:ok,
     socket
     |> assign(:page_title, "Companies")
     |> assign(:infinite_scroll, %{})
     |> assign(:blueprints, blueprints)
     |> assign(:launch_summary, launch_summary(blueprints, user_id))
     |> assign(:featured_blueprints, Enum.take(blueprints, 5))
     |> init_stream(:companies, &fetch_companies(user_id, &1))}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Companies")
    |> assign(:company, nil)
  end

  defp apply_action(socket, nil, params) do
    apply_action(socket, :index, params)
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New Company")
    |> assign(:company, %Companies.Company{})
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    company = Companies.get_company!(id)

    socket
    |> assign(:page_title, "Edit Company")
    |> assign(:company, company)
  end

  @impl true
  def handle_event("delete_company", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    if company_manager?(user_id, id) do
      company = Companies.get_company!(id)
      {:ok, _} = Companies.delete_company(company)

      {:noreply,
       socket
       |> refresh_launch_summary()
       |> reset_stream(:companies, &fetch_companies(user_id, &1))
       |> put_flash(:info, "Company deleted successfully")}
    else
      {:noreply, put_flash(socket, :error, "Company not found or you cannot manage it.")}
    end
  end

  def handle_event("next-page", _params, socket) do
    user_id = socket.assigns.current_user.id
    {:reply, %{}, load_next(socket, :companies, &fetch_companies(user_id, &1))}
  end

  defp fetch_companies(user_id, cursor) do
    Companies.list_companies_for_user_page(user_id, after: cursor)
  end

  def format_inserted_at(company) do
    Calendar.strftime(company.inserted_at, "%Y-%m-%d %H:%M")
  end

  defp launch_summary(blueprints, user_id) do
    companies = Companies.list_companies_for_user(user_id)
    active_count = Enum.count(companies, &(&1.status == "active"))
    paused_count = Enum.count(companies, &(&1.status == "paused"))

    %{
      total_companies: length(companies),
      active_companies: active_count,
      paused_companies: paused_count,
      blueprint_count: length(blueprints),
      default_agent_count: Enum.reduce(blueprints, 0, &(&1.default_agent_count + &2)),
      capability_count:
        blueprints
        |> Enum.flat_map(& &1.capability_tags)
        |> Enum.uniq()
        |> length(),
      seed_issue_count: Enum.reduce(blueprints, 0, &(&1.seed_issue_count + &2)),
      launch_posture: launch_posture(length(companies), active_count, paused_count)
    }
  end

  defp refresh_launch_summary(socket) do
    assign(
      socket,
      :launch_summary,
      launch_summary(socket.assigns.blueprints, socket.assigns.current_user.id)
    )
  end

  def can_manage_company?(user, company) do
    company_manager?(user && user.id, company && company.id)
  end

  defp company_manager?(user_id, company_id)
       when is_binary(user_id) and is_binary(company_id) do
    Companies.admin?(user_id, company_id) or Companies.is_board_member?(user_id, company_id)
  end

  defp company_manager?(_user_id, _company_id), do: false

  defp launch_posture(0, _active_count, _paused_count) do
    %{
      label: "No companies yet",
      detail:
        "Start from a blueprint to create agents, goals, a project, and seed work in one launch.",
      tone: :attention
    }
  end

  defp launch_posture(_total, 0, paused_count) when paused_count > 0 do
    %{
      label: "All companies paused",
      detail:
        "Resume an existing company or launch a fresh blueprint before assigning runtime work.",
      tone: :warning
    }
  end

  defp launch_posture(_total, active_count, paused_count) do
    %{
      label: "#{active_count} active companies",
      detail:
        "#{paused_count} paused. Use blueprints for new operating companies or import a portable backup.",
      tone: :ready
    }
  end

  defp posture_badge_class(:ready),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"

  defp posture_badge_class(:warning),
    do: "border-amber-500/25 bg-amber-500/10 text-amber-200"

  defp posture_badge_class(:attention),
    do: "border-brand/25 bg-brand/10 text-brand"

  defp posture_badge_class(_tone), do: "border-border bg-surface text-text-tertiary"
end
