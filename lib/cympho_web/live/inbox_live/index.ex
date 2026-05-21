defmodule CymphoWeb.InboxLive.Index do
  use CymphoWeb, :live_view
  alias Cympho.Inbox
  alias Cympho.Agents

  @statuses ~w(unread read dismissed archived review)

  @impl true
  def mount(_params, _session, socket) do
    company_id =
      if socket.assigns[:current_company], do: socket.assigns.current_company.id, else: nil

    agents = if company_id, do: Agents.list_agents_by_company(company_id), else: []

    socket =
      socket
      |> assign(:page_title, "Inbox")
      |> assign(:agents, agents)
      |> assign(:selected_agent_id, nil)
      |> assign(:selected_agent, nil)
      |> assign(:subscribed_agent_id, nil)
      |> assign(:current_status, nil)
      |> assign(:digest_density, "detailed")
      |> assign(:inbox_items, [])
      |> assign(:inbox_counts, %{})
      |> assign(:agent_counts, %{})

    if connected?(socket) do
      if socket.assigns.selected_agent_id do
        Inbox.subscribe(socket.assigns.selected_agent_id)
      end

      if socket.assigns[:current_company] do
        CymphoWeb.Events.subscribe_to_runs(socket.assigns.current_company.id)
      end
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    status = normalize_status(params["status"])
    digest_density = normalize_digest_density(params["density"])

    agent_id =
      params["agent_id"]
      |> normalize_agent_id()
      |> authorized_agent_id(socket)

    socket =
      socket
      |> assign(:current_status, status)
      |> assign(:digest_density, digest_density)
      |> assign(:selected_agent_id, agent_id)
      |> assign(:selected_agent, selected_agent(socket.assigns.agents, agent_id))
      |> maybe_subscribe_to_agent()
      |> load_inbox()

    {:noreply, socket}
  end

  @impl true
  def handle_info({:inbox_updated, _state}, socket) do
    {:noreply, load_inbox(socket)}
  end

  def handle_info({:inbox_created, _state}, socket) do
    {:noreply, load_inbox(socket)}
  end

  def handle_info({:run_status_changed, payload}, socket) do
    selected_agent_id = socket.assigns[:selected_agent_id]

    socket =
      if selected_agent_id == "all" or payload[:agent_id] == selected_agent_id do
        {message, type} =
          case payload do
            %{new_status: "completed"} -> {"Agent completed a run", "success"}
            %{new_status: "failed"} -> {"Agent run failed", "error"}
            %{new_status: "cancelled"} -> {"Agent run cancelled", "warning"}
            _ -> {"Agent run status changed", "info"}
          end

        push_event(socket, "toast", %{
          message: message,
          type: type,
          key: "run_#{payload[:run_id]}"
        })
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info(msg, socket) do
    require Logger
    Logger.warning("Unhandled message in InboxLive.Index: #{inspect(msg)}")
    {:noreply, socket}
  end

  @impl true
  def handle_event("mark_read", params, socket) do
    inbox_action(socket, params, &Inbox.mark_read/2)
  end

  def handle_event("dismiss", params, socket) do
    inbox_action(socket, params, &Inbox.dismiss/2)
  end

  def handle_event("archive", params, socket) do
    inbox_action(socket, params, &Inbox.archive/2)
  end

  def handle_event("restore", params, socket) do
    inbox_action(socket, params, &Inbox.restore/2)
  end

  def handle_event("filter_status", %{"status" => status}, socket) do
    {:noreply, push_patch(socket, to: build_url(socket, %{"status" => status}))}
  end

  def handle_event(
        "approve_review",
        %{"issue_id" => issue_id, "wake_id" => wake_id},
        socket
      ) do
    handle_review_action(socket, issue_id, wake_id, :done, "Issue approved and closed.")
  end

  def handle_event(
        "request_review_changes",
        %{"issue_id" => issue_id, "wake_id" => wake_id},
        socket
      ) do
    handle_review_action(
      socket,
      issue_id,
      wake_id,
      :todo,
      "Sent back to engineering for changes."
    )
  end

  def handle_event("select_agent", %{"agent_id" => "all"}, socket) do
    socket =
      socket
      |> assign(:selected_agent_id, "all")
      |> maybe_subscribe_to_agent()
      |> load_inbox()

    {:noreply, push_patch(socket, to: build_url(socket, %{"agent_id" => "all"}))}
  end

  def handle_event("select_agent", %{"agent_id" => agent_id}, socket) do
    case authorize_agent_access(agent_id, socket) do
      {:ok, _agent} ->
        socket =
          socket
          |> assign(:selected_agent_id, agent_id)
          |> maybe_subscribe_to_agent()
          |> load_inbox()

        {:noreply, push_patch(socket, to: build_url(socket, %{"agent_id" => agent_id}))}

      {:error, :unauthorized} ->
        {:noreply,
         put_flash(socket, :error, "You don't have permission to access this agent's inbox")}
    end
  end

  defp inbox_action(socket, %{"issue_id" => issue_id} = params, fun) do
    agent_id = Map.get(params, "agent_id") || socket.assigns.selected_agent_id

    with {:ok, _agent} <- authorize_agent_access(agent_id, socket),
         {:ok, _} <- fun.(issue_id, agent_id) do
      {:noreply, load_inbox(socket)}
    else
      {:error, :unauthorized} ->
        {:noreply,
         put_flash(socket, :error, "You don't have permission to access this agent's inbox")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Inbox entry not found")}
    end
  end

  defp handle_review_action(socket, issue_id, wake_id, target_status, ok_message) do
    with {:ok, issue} <- scoped_get_issue(socket, issue_id),
         {:ok, _} <- transition_for_review(issue, target_status),
         :ok <- consume_wake_if_present(wake_id) do
      {:noreply,
       socket
       |> put_flash(:info, ok_message)
       |> load_inbox()}
    else
      {:error, reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Could not complete review action: #{inspect(reason)}"
         )}
    end
  end

  # `transition_issue_with_review_gates/3` runs the same quality gates an
  # agent's approve_issue action hits, so a human approving from the inbox
  # gets the same enforcement.
  defp transition_for_review(issue, :done) do
    Cympho.Issues.transition_issue_with_review_gates(issue, :done, nil)
  end

  defp transition_for_review(issue, :todo) do
    Cympho.Issues.transition_issue(issue, :todo)
  end

  defp consume_wake_if_present(nil), do: :ok
  defp consume_wake_if_present(""), do: :ok

  defp consume_wake_if_present(wake_id) do
    case Cympho.Wakes.get_agent_wake(wake_id) do
      {:ok, wake} ->
        _ = Cympho.Wakes.consume_wake(wake)
        :ok

      _ ->
        :ok
    end
  end

  defp scoped_get_issue(socket, issue_id) do
    case socket.assigns[:current_company] do
      %{id: company_id} -> Cympho.Issues.get_company_issue(company_id, issue_id)
      _ -> Cympho.Issues.get_issue(issue_id)
    end
  end

  defp load_inbox(socket) do
    agent_id = socket.assigns[:selected_agent_id]
    status = socket.assigns[:current_status]
    company_id = socket.assigns[:current_company] && socket.assigns.current_company.id

    items =
      cond do
        status == "review" ->
          build_review_queue_items(agent_id, company_id)

        agent_id == "all" and company_id ->
          opts = [limit: 100] ++ if(status, do: [status: status], else: [])
          Inbox.list_recent_for_company(company_id, opts)

        agent_id in [nil, "", "all"] ->
          []

        true ->
          opts = if status, do: [status: status], else: []
          Inbox.list_inbox_for_agent(agent_id, opts)
      end

    counts =
      cond do
        agent_id == "all" and company_id -> Inbox.status_counts_for_company(company_id)
        agent_id in [nil, "", "all"] -> %{}
        true -> Inbox.status_counts_for_agent(agent_id)
      end

    counts = Map.put(counts, "review", review_queue_count(agent_id, company_id))

    agent_counts =
      if company_id, do: Inbox.counts_by_agent_for_company(company_id), else: %{}

    socket
    |> assign(:inbox_items, items)
    |> assign(:inbox_counts, normalize_counts(counts))
    |> assign(:agent_counts, agent_counts)
  end

  # Returns the "Awaiting my review" pseudo-items: wake-driven entries that
  # share the inbox row shape so the existing template can render them.
  # `kind: :review_queue` tags each so we can swap action buttons.
  defp build_review_queue_items(agent_id, company_id) do
    scope = review_scope(agent_id, company_id)

    scope
    |> Cympho.Wakes.list_review_queue(limit: 100)
    |> Enum.map(fn %{wake: wake, issue: issue} ->
      %{
        kind: :review_queue,
        wake: wake,
        wake_id: wake.id,
        issue: issue,
        issue_id: issue.id,
        agent: wake.agent,
        agent_id: wake.agent_id,
        status: "review",
        review_nudge: nil,
        inserted_at: wake.inserted_at
      }
    end)
  end

  defp review_queue_count(agent_id, company_id) do
    scope = review_scope(agent_id, company_id)
    scope |> Cympho.Wakes.list_review_queue(limit: 200) |> length()
  end

  defp review_scope(agent_id, company_id) do
    cond do
      agent_id in [nil, "", "all"] and is_binary(company_id) -> {:company, company_id}
      is_binary(agent_id) -> {:agent, agent_id}
      true -> {:agent, nil}
    end
  end

  defp build_url(socket, overrides) do
    status = Map.get(overrides, "status", socket.assigns.current_status)
    agent_id = Map.get(overrides, "agent_id", socket.assigns.selected_agent_id)
    digest_density = Map.get(overrides, "density", socket.assigns.digest_density)

    query =
      %{
        status: status,
        agent_id: agent_id,
        density: digest_density
      }
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
      |> Enum.into(%{})

    ~p"/inbox?#{query}"
  end

  defp inbox_url(selected_agent_id, status, density, overrides) do
    status = Map.get(overrides, :status, status)
    agent_id = Map.get(overrides, :agent_id, selected_agent_id)
    density = Map.get(overrides, :density, density)

    query =
      %{
        status: status,
        agent_id: agent_id,
        density: density
      }
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
      |> Enum.into(%{})

    ~p"/inbox?#{query}"
  end

  defp authorize_agent_access(nil, _socket), do: {:error, :unauthorized}
  defp authorize_agent_access("all", _socket), do: {:ok, :all}

  defp authorize_agent_access(agent_id, socket) do
    company_id = socket.assigns[:current_company] && socket.assigns.current_company.id

    if company_id do
      case Agents.get_company_agent(company_id, agent_id) do
        {:ok, agent} -> {:ok, agent}
        {:error, :not_found} -> {:error, :unauthorized}
      end
    else
      {:error, :unauthorized}
    end
  end

  defp maybe_subscribe_to_agent(socket) do
    agent_id = socket.assigns[:selected_agent_id]
    subscribed_id = socket.assigns[:subscribed_agent_id]

    if connected?(socket) && agent_id && agent_id != "all" && agent_id != subscribed_id do
      if subscribed_id && subscribed_id != "all" do
        Inbox.unsubscribe(subscribed_id)
      end

      Inbox.subscribe(agent_id)
      assign(socket, :subscribed_agent_id, agent_id)
    else
      socket
    end
  end

  defp normalize_status(status) when status in @statuses, do: status
  defp normalize_status(_), do: nil

  defp normalize_digest_density("compact"), do: "compact"
  defp normalize_digest_density("detailed"), do: "detailed"
  defp normalize_digest_density(_), do: "detailed"

  defp normalize_agent_id("all"), do: "all"
  defp normalize_agent_id(agent_id) when is_binary(agent_id) and agent_id != "", do: agent_id
  defp normalize_agent_id(_), do: "all"

  defp authorized_agent_id("all", _socket), do: "all"

  defp authorized_agent_id(agent_id, socket) do
    case authorize_agent_access(agent_id, socket) do
      {:ok, _agent} -> agent_id
      {:error, :unauthorized} -> "all"
    end
  end

  defp selected_agent(_agents, "all"), do: nil
  defp selected_agent(agents, agent_id), do: Enum.find(agents, &(&1.id == agent_id))

  defp normalize_counts(counts) do
    Map.merge(%{"unread" => 0, "read" => 0, "dismissed" => 0, "archived" => 0}, counts)
  end

  defp count_for(counts, status), do: Map.get(counts, status, 0)

  defp total_count(counts) do
    @statuses
    |> Enum.map(&count_for(counts, &1))
    |> Enum.sum()
  end

  defp agent_option_label(agent, agent_counts) do
    counts = Map.get(agent_counts, agent.id, %{})
    total = total_count(normalize_counts(counts))
    unread = Map.get(counts, "unread", 0)

    cond do
      unread > 0 -> "#{agent.name} (#{unread} unread)"
      total > 0 -> "#{agent.name} (#{total})"
      true -> agent.name
    end
  end

  defp inbox_scope_label("all", _agent), do: "All agents"
  defp inbox_scope_label(_agent_id, %{name: name}), do: name
  defp inbox_scope_label(_agent_id, _agent), do: "Selected agent"

  defp status_filter_label(nil), do: "All"
  defp status_filter_label(status), do: String.capitalize(status)

  defp status_dot("unread"), do: "bg-blue-400"
  defp status_dot("read"), do: "bg-slate-400"
  defp status_dot("dismissed"), do: "bg-amber-400"
  defp status_dot("archived"), do: "bg-red-400"
  defp status_dot("review"), do: "bg-brand"
  defp status_dot(_), do: "bg-slate-500"

  defp status_badge_class("unread"), do: "bg-blue-500/20 text-blue-400"
  defp status_badge_class("read"), do: "bg-gray-500/20 text-gray-400"
  defp status_badge_class("dismissed"), do: "bg-yellow-500/20 text-yellow-400"
  defp status_badge_class("archived"), do: "bg-red-500/20 text-red-400"
  defp status_badge_class("review"), do: "bg-brand/20 text-brand"
  defp status_badge_class(_), do: "bg-gray-500/20 text-gray-400"

  defp status_tab_class(current, status) do
    if current == status do
      "border-brand bg-brand/15 text-text-primary"
    else
      "border-border bg-surface text-text-tertiary hover:bg-surface-hover hover:text-text-secondary"
    end
  end

  defp density_tab_class(current, density) do
    if current == density do
      "bg-brand text-white"
    else
      "text-text-tertiary hover:bg-surface-hover hover:text-text-primary"
    end
  end

  defp priority_badge_class(:critical), do: "border-red-500/25 bg-red-500/15 text-red-300"
  defp priority_badge_class(:high), do: "border-red-500/20 bg-red-500/10 text-red-300"
  defp priority_badge_class(:medium), do: "border-yellow-500/20 bg-yellow-500/10 text-yellow-300"
  defp priority_badge_class(:low), do: "border-slate-500/20 bg-slate-500/10 text-slate-300"
  defp priority_badge_class(_), do: "border-border bg-surface text-text-quaternary"

  defp issue_status_label(status) when is_atom(status) do
    status |> to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  defp issue_status_label(status) when is_binary(status) do
    status |> String.replace("_", " ") |> String.capitalize()
  end

  defp issue_status_label(_), do: "Unknown"

  defp priority_label(priority) when is_atom(priority),
    do: priority |> to_string() |> String.capitalize()

  defp priority_label(priority) when is_binary(priority), do: String.capitalize(priority)
  defp priority_label(_), do: "No priority"

  defp issue_description(%{description: description}) when is_binary(description) do
    description
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 180)
  end

  defp issue_description(_), do: nil

  defp target_agent_name(%{agent: %{name: name}}, _selected_agent) when is_binary(name), do: name
  defp target_agent_name(_item, %{name: name}) when is_binary(name), do: name
  defp target_agent_name(_item, _selected_agent), do: "Unknown agent"

  defp issue_link(issue) when is_nil(issue), do: "#"
  defp issue_link(issue), do: ~p"/issues/#{issue.id}"

  defp format_timestamp(nil), do: "-"
  defp format_timestamp(dt), do: Calendar.strftime(dt, "%b %d, %H:%M")
end
