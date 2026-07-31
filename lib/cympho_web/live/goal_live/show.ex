defmodule CymphoWeb.GoalLive.Show do
  use CymphoWeb, :live_view
  import Ecto.Query
  alias Cympho.{Goals, Repo}
  alias Cympho.Issues.Issue

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case get_scoped_goal(socket, id) do
      {:ok, goal} ->
        {:ok,
         socket
         |> assign(:goal, goal)
         |> assign(:issues, list_goal_issues(goal))
         |> assign(:status_counts, status_counts(goal))}

      {:error, :not_found} ->
        {:ok, push_navigate(socket, to: ~p"/goals")}
    end
  end

  @impl true
  def handle_params(%{"id" => id}, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, id)}
  end

  defp apply_action(socket, nil, id), do: apply_action(socket, :show, id)

  defp apply_action(socket, :show, id) do
    case get_scoped_goal(socket, id) do
      {:ok, goal} ->
        socket
        |> assign(:page_title, goal.title)
        |> assign(:goal, goal)
        |> assign(:issues, list_goal_issues(goal))
        |> assign(:status_counts, status_counts(goal))

      {:error, :not_found} ->
        socket
        |> put_flash(:error, "Goal not found")
        |> push_navigate(to: ~p"/goals")
    end
  end

  defp list_goal_issues(%{id: goal_id}) do
    Issue
    |> where(goal_id: ^goal_id)
    |> order_by(desc: :inserted_at)
    |> limit(10)
    |> Repo.all()
  end

  defp status_counts(%{id: goal_id}) do
    Issue
    |> where(goal_id: ^goal_id)
    |> group_by(:status)
    |> select([i], {i.status, count(i.id)})
    |> Repo.all()
    |> Map.new()
  end

  def status_label(:in_progress), do: "In progress"
  def status_label(:in_review), do: "In review"
  def status_label(s), do: s |> to_string() |> String.capitalize()

  @doc "Rolls the raw status counts into a single on-track glance."
  def goal_summary(status_counts) do
    total = status_counts |> Map.values() |> Enum.sum()
    done = Map.get(status_counts, :done, 0)

    %{
      total: total,
      done: done,
      open:
        Map.get(status_counts, :backlog, 0) + Map.get(status_counts, :todo, 0) +
          Map.get(status_counts, :in_progress, 0),
      in_review: Map.get(status_counts, :in_review, 0),
      blocked: Map.get(status_counts, :blocked, 0),
      percent: if(total > 0, do: round(done / total * 100), else: 0)
    }
  end

  # Row-level status reads as a colored dot: every row in a young goal carries the
  # same word, so the pill was six repetitions of "Todo" instead of a signal.
  def status_dot_class(:todo), do: "bg-accent"
  def status_dot_class(:in_progress), do: "bg-brand"
  def status_dot_class(:in_review), do: "bg-violet-300"
  def status_dot_class(:done), do: "bg-emerald-400"
  def status_dot_class(:blocked), do: "bg-red-400"
  def status_dot_class(_status), do: "bg-text-quaternary"

  def progress_width(percent) when is_integer(percent),
    do: "width: #{max(min(percent, 100), 0)}%"

  def progress_width(_percent), do: "width: 0%"

  # True when an issue moved in the last week — powers the "what moved" grouping.
  def recent_issue?(%{updated_at: %DateTime{} = at}),
    do: DateTime.diff(DateTime.utc_now(), at, :day) <= 7

  def recent_issue?(_issue), do: false

  def moved_label(%DateTime{} = at) do
    case DateTime.diff(DateTime.utc_now(), at, :day) do
      0 -> "today"
      d -> "#{d}d ago"
    end
  end

  def moved_label(_at), do: nil

  attr :issue, :map, required: true

  def issue_row(assigns) do
    ~H"""
    <.app_link
      navigate={~p"/issues/#{@issue.id}"}
      class="group flex items-center gap-3 px-3 py-2.5 transition-colors hover:bg-surface-2 hover:shadow-[inset_2px_0_0_0_var(--color-primary)]"
    >
      <span
        role="img"
        aria-label={status_label(@issue.status)}
        title={status_label(@issue.status)}
        class={["h-2 w-2 shrink-0 rounded-full", status_dot_class(@issue.status)]}
      >
      </span>
      <span :if={@issue.identifier} class="font-mono text-caption text-ink-tertiary shrink-0">
        {@issue.identifier}
      </span>
      <span class="flex-1 truncate text-body text-ink-muted group-hover:text-ink">
        {@issue.title}
      </span>
      <span :if={moved_label(@issue.updated_at)} class="shrink-0 text-caption text-ink-tertiary">
        {moved_label(@issue.updated_at)}
      </span>
      <.badge variant="priority" value={to_string(@issue.priority)} />
    </.app_link>
    """
  end

  defp get_scoped_goal(socket, id) do
    with {:ok, goal} <- Goals.get_goal(id),
         :ok <- authorize_goal(socket, goal) do
      {:ok, goal}
    end
  end

  defp authorize_goal(socket, goal) do
    case socket.assigns[:current_company] do
      %{id: company_id} when goal.company_id == company_id -> :ok
      nil -> :ok
      _ -> {:error, :not_found}
    end
  end
end
