defmodule CymphoWeb.IssueLive.MyIssues do
  use CymphoWeb, :live_view
  alias Cympho.Issues
  alias Cympho.Agents

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) && socket.assigns[:current_company] do
      Issues.subscribe(socket.assigns.current_company.id)
    end

    {:ok,
     socket
     |> assign(:page_title, "My Issues")
     |> assign(:agents, [])
     |> assign(:current_tab, "active")}
  end

  @impl true
  def handle_params(params, _url, socket) do
    tab = params["tab"] || "active"
    user = socket.assigns[:current_user]
    company = socket.assigns[:current_company]

    agents =
      if company do
        Agents.list_agents_by_company(company.id)
      else
        []
      end

    agent_ids = Enum.map(agents, & &1.id)

    issues =
      case tab do
        "active" -> list_active_issues(agent_ids)
        "created_by_me" -> list_user_created_issues(user)
        "watching" -> list_watching_issues(agent_ids)
        "all" -> list_all_company_issues(company, agent_ids)
        _ -> []
      end

    socket =
      socket
      |> assign(:issues, issues)
      |> assign(:agents, agents)
      |> assign(:current_tab, tab)

    {:noreply, socket}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, push_patch(socket, to: ~p"/my-issues?tab=#{tab}")}
  end

  @impl true
  def handle_info({:issue_created, _issue}, socket), do: {:noreply, reload(socket)}
  def handle_info({:issue_updated, _issue}, socket), do: {:noreply, reload(socket)}
  def handle_info({:issue_deleted, _id}, socket), do: {:noreply, reload(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp reload(socket) do
    tab = socket.assigns.current_tab
    agent_ids = Enum.map(socket.assigns.agents, & &1.id)
    user = socket.assigns[:current_user]
    company = socket.assigns[:current_company]

    issues =
      case tab do
        "active" -> list_active_issues(agent_ids)
        "created_by_me" -> list_user_created_issues(user)
        "watching" -> list_watching_issues(agent_ids)
        "all" -> list_all_company_issues(company, agent_ids)
        _ -> []
      end

    assign(socket, :issues, issues)
  end

  defp list_active_issues(agent_ids) when agent_ids == [], do: []

  defp list_active_issues(agent_ids) do
    import Ecto.Query

    Cympho.Issues.Issue
    |> where([i], i.assignee_id in ^agent_ids)
    |> where([i], i.status in [:todo, :in_progress, :in_review, :blocked])
    |> order_by([i], desc: i.updated_at)
    |> Cympho.Repo.all()
    |> Cympho.Repo.preload([:assignee, :project, :labels])
  end

  defp list_user_created_issues(nil), do: []

  defp list_user_created_issues(_user) do
    import Ecto.Query

    Cympho.Issues.Issue
    |> where([i], i.status not in [:done, :cancelled])
    |> order_by([i], desc: i.updated_at)
    |> limit(50)
    |> Cympho.Repo.all()
    |> Cympho.Repo.preload([:assignee, :project, :labels])
  end

  defp list_watching_issues(agent_ids) when agent_ids == [], do: []

  defp list_watching_issues(agent_ids) do
    import Ecto.Query

    Cympho.Issues.Issue
    |> where([i], i.assignee_id in ^agent_ids)
    |> order_by([i], desc: i.updated_at)
    |> limit(50)
    |> Cympho.Repo.all()
    |> Cympho.Repo.preload([:assignee, :project, :labels])
  end

  defp list_all_company_issues(nil, _agent_ids), do: []

  defp list_all_company_issues(company, agent_ids) do
    import Ecto.Query

    Cympho.Issues.Issue
    |> where([i], i.assignee_id in ^agent_ids or i.company_id == ^company.id)
    |> where([i], i.status not in [:done, :cancelled])
    |> order_by([i], desc: i.updated_at)
    |> limit(100)
    |> Cympho.Repo.all()
    |> Cympho.Repo.preload([:assignee, :project, :labels])
  end

  def status_color(:backlog), do: "bg-gray-400"
  def status_color(:todo), do: "bg-blue-400"
  def status_color(:in_progress), do: "bg-yellow-400"
  def status_color(:in_review), do: "bg-purple-400"
  def status_color(:done), do: "bg-green-400"
  def status_color(:blocked), do: "bg-red-400"
  def status_color(_), do: "bg-gray-400"

  def priority_color(:critical), do: "text-red-400"
  def priority_color(:high), do: "text-orange-400"
  def priority_color(:medium), do: "text-yellow-400"
  def priority_color(:low), do: "text-gray-400"
  def priority_color(_), do: "text-gray-400"

  def tab_active?("active", "active"), do: "bg-surface-hover text-text-primary"
  def tab_active?("created_by_me", "created_by_me"), do: "bg-surface-hover text-text-primary"
  def tab_active?("watching", "watching"), do: "bg-surface-hover text-text-primary"
  def tab_active?("all", "all"), do: "bg-surface-hover text-text-primary"
  def tab_active?(_, _), do: "text-text-secondary hover:text-text-primary"
end
