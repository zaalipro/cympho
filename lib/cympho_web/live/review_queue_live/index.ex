defmodule CymphoWeb.ReviewQueueLive.Index do
  use CymphoWeb, :live_view
  alias Cympho.Issues

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) && socket.assigns[:current_company] do
      Issues.subscribe(socket.assigns.current_company.id)
    end

    {:ok,
     socket
     |> assign(:page_title, "Review queue")
     |> load_lanes()}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, load_lanes(socket)}
  end

  @impl true
  def handle_info({:issue_created, _issue}, socket), do: {:noreply, load_lanes(socket)}
  def handle_info({:issue_updated, _issue}, socket), do: {:noreply, load_lanes(socket)}
  def handle_info({:issue_deleted, _id}, socket), do: {:noreply, load_lanes(socket)}
  def handle_info(_other, socket), do: {:noreply, socket}

  defp load_lanes(socket) do
    case socket.assigns[:current_company] do
      nil ->
        socket
        |> assign(:awaiting_review, [])
        |> assign(:kicked_back, [])
        |> assign(:spec_review, [])
        |> assign(:stats, empty_stats())

      company ->
        awaiting = list_awaiting_review(company.id)
        kicked_back = list_kicked_back(company.id)
        spec_review = list_spec_review(company.id)

        socket
        |> assign(:awaiting_review, awaiting)
        |> assign(:kicked_back, kicked_back)
        |> assign(:spec_review, spec_review)
        |> assign(:stats, build_stats(awaiting, kicked_back, spec_review))
    end
  end

  defp list_awaiting_review(company_id) do
    import Ecto.Query

    Cympho.Issues.Issue
    |> where([i], i.company_id == ^company_id)
    |> where([i], i.status == :in_review)
    |> order_by([i], asc: i.updated_at)
    |> Cympho.Repo.all()
    |> Cympho.Repo.preload([:assignee, :project, :last_reviewer])
  end

  defp list_kicked_back(company_id) do
    import Ecto.Query

    Cympho.Issues.Issue
    |> where([i], i.company_id == ^company_id)
    |> where([i], i.status == :todo and not is_nil(i.last_reviewer_id))
    |> order_by([i], asc: i.updated_at)
    |> Cympho.Repo.all()
    |> Cympho.Repo.preload([:assignee, :project, :last_reviewer])
  end

  defp list_spec_review(company_id) do
    import Ecto.Query

    Cympho.Issues.Issue
    |> where([i], i.company_id == ^company_id)
    |> where([i], i.status == :backlog and i.assigned_role == "cto")
    |> where([i], fragment("?->>'spec_review_required' = ?", i.monitor_state, "true"))
    |> order_by([i], asc: i.inserted_at)
    |> Cympho.Repo.all()
    |> Cympho.Repo.preload([:project])
  end

  defp empty_stats do
    %{total: 0, oldest_age_hours: nil, by_role: %{}}
  end

  defp build_stats(awaiting, kicked_back, spec_review) do
    all = awaiting ++ kicked_back ++ spec_review

    oldest =
      all
      |> Enum.map(& &1.updated_at)
      |> Enum.min(DateTime, fn -> nil end)

    age_hours =
      case oldest do
        nil ->
          nil

        dt ->
          diff = DateTime.diff(DateTime.utc_now(), dt, :second)
          Float.round(diff / 3600, 1)
      end

    by_role =
      awaiting
      |> Enum.group_by(& &1.assigned_role)
      |> Map.new(fn {role, list} -> {role || "unassigned", length(list)} end)

    %{total: length(all), oldest_age_hours: age_hours, by_role: by_role}
  end

  def status_color(:backlog), do: "bg-gray-400"
  def status_color(:todo), do: "bg-blue-400"
  def status_color(:in_progress), do: "bg-yellow-400"
  def status_color(:in_review), do: "bg-purple-400"
  def status_color(:done), do: "bg-green-400"
  def status_color(:blocked), do: "bg-red-400"
  def status_color(_), do: "bg-gray-400"

  def format_age(updated_at) do
    diff_sec = DateTime.diff(DateTime.utc_now(), updated_at, :second)

    cond do
      diff_sec < 60 -> "just now"
      diff_sec < 3_600 -> "#{div(diff_sec, 60)}m"
      diff_sec < 86_400 -> "#{div(diff_sec, 3_600)}h"
      true -> "#{div(diff_sec, 86_400)}d"
    end
  end
end
