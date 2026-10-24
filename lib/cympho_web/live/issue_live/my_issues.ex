defmodule CymphoWeb.IssueLive.MyIssues do
  use CymphoWeb, :live_view
  import Ecto.Query
  alias Cympho.Issues
  alias Cympho.Agents
  alias Cympho.Repo

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) && socket.assigns[:current_company] do
      Issues.subscribe(socket.assigns.current_company.id)
    end

    {:ok,
     socket
     |> assign(:page_title, "Mine")
     |> assign(:agents, [])
     |> assign(:infinite_scroll, %{})
     |> assign(:current_tab, "active")}
  end

  @impl true
  def handle_params(params, _url, socket) do
    tab = params["tab"] || "active"
    company = socket.assigns[:current_company]

    agents =
      if company do
        Agents.list_agents_by_company(company.id)
      else
        []
      end

    socket =
      socket
      |> assign(:agents, agents)
      |> assign(:current_tab, tab)

    socket = assign(socket, :multiple_projects?, multiple_projects?(socket))

    {:noreply, init_stream(socket, :issues, &fetch_issues(socket, &1))}
  end

  @impl true
  def handle_event("next-page", _params, socket) do
    {:reply, %{}, load_next(socket, :issues, &fetch_issues(socket, &1))}
  end

  @impl true
  def handle_info({:issue_created, _issue}, socket), do: {:noreply, reload(socket)}
  def handle_info({:issue_updated, _issue}, socket), do: {:noreply, reload(socket)}
  def handle_info({:issue_deleted, _id}, socket), do: {:noreply, reload(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp reload(socket) do
    socket
    |> assign(:multiple_projects?, multiple_projects?(socket))
    |> reset_stream(:issues, &fetch_issues(socket, &1))
  end

  defp fetch_issues(socket, cursor) do
    case issues_query(socket) do
      nil -> empty_page()
      query -> Issues.paginate_issues_query(query, after: cursor)
    end
  end

  defp issues_query(socket) do
    agent_ids = Enum.map(socket.assigns.agents, & &1.id)
    user = socket.assigns[:current_user]
    company = socket.assigns[:current_company]

    case socket.assigns.current_tab do
      "active" -> active_issues_query(agent_ids)
      "created_by_me" -> user_created_issues_query(user, company)
      "watching" -> watching_issues_query(agent_ids)
      "all" -> all_company_issues_query(company, agent_ids)
      _ -> nil
    end
  end

  # The project chip repeats the same name on every row when the list covers a
  # single project, so it only earns its space once the list spans more.
  defp multiple_projects?(socket) do
    case issues_query(socket) do
      nil ->
        false

      query ->
        project_ids =
          query
          |> where([i], not is_nil(i.project_id))
          |> distinct(true)
          |> select([i], i.project_id)
          |> Repo.all()

        length(project_ids) > 1
    end
  end

  defp empty_page do
    %Cympho.Pagination.Page{entries: [], next_cursor: nil, has_more?: false}
  end

  defp active_issues_query([]), do: nil

  defp active_issues_query(agent_ids) do
    Cympho.Issues.Issue
    |> where([i], i.assignee_id in ^agent_ids)
    |> where([i], i.status in [:todo, :in_progress, :in_review, :blocked])
  end

  defp user_created_issues_query(nil, _company), do: nil
  defp user_created_issues_query(_user, nil), do: nil

  defp user_created_issues_query(user, company) do
    Cympho.Issues.Issue
    |> where([i], i.created_by_user_id == ^user.id and i.company_id == ^company.id)
    |> where([i], i.status not in [:done, :cancelled])
  end

  defp watching_issues_query([]), do: nil

  defp watching_issues_query(agent_ids) do
    Cympho.Issues.Issue
    |> where([i], i.assignee_id in ^agent_ids)
  end

  defp all_company_issues_query(nil, _agent_ids), do: nil

  defp all_company_issues_query(company, agent_ids) do
    Cympho.Issues.Issue
    |> where([i], i.assignee_id in ^agent_ids or i.company_id == ^company.id)
    |> where([i], i.status not in [:done, :cancelled])
  end

  @tabs [
    {"active", "Active"},
    {"created_by_me", "Created by me"},
    {"watching", "Watching"},
    {"all", "All"}
  ]

  # Mine keeps its four meanings, one tab each.
  def tabs, do: @tabs

  # The owner's words for task states (v2 spec §1.4), with their shape.
  def status_state(:backlog), do: {:idle, "Later"}
  def status_state(:todo), do: {:idle, "To do"}
  def status_state(:in_progress), do: {:working, "Working"}
  def status_state(:in_review), do: {:waiting, "In review"}
  def status_state(:blocked), do: {:stopped, "Blocked"}
  def status_state(:done), do: {:done, "Done"}
  def status_state(_cancelled), do: {:idle, "Cancelled"}
end
