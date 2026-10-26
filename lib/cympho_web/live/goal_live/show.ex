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

  defp list_goal_issues(%{id: goal_id, company_id: company_id}) do
    Issue
    |> where(goal_id: ^goal_id, company_id: ^company_id)
    |> order_by(desc: :inserted_at)
    |> limit(10)
    |> Repo.all()
  end

  defp status_counts(%{id: goal_id, company_id: company_id}) do
    Issue
    |> where(goal_id: ^goal_id, company_id: ^company_id)
    |> group_by(:status)
    |> select([i], {i.status, count(i.id)})
    |> Repo.all()
    |> Map.new()
  end

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

  @doc "A linked task as a row: its status word, ID, when it last moved and a High/Critical priority."
  def goal_issue_row(assigns) do
    ~H"""
    <.list_row
      id={"goal-task-#{@issue.id}"}
      title={@issue.title}
      navigate={~p"/issues/#{@issue.id}"}
      status={CymphoWeb.IssueLive.MyIssues.status_state(@issue.status)}
    >
      <:meta>
        <span :if={@issue.identifier} class="mono">{@issue.identifier}</span><span
          :if={@issue.identifier && moved_label(@issue.updated_at)}
          aria-hidden="true"
        > · </span><span :if={moved_label(@issue.updated_at)}>Moved {moved_label(
          @issue.updated_at
        )}</span>
      </:meta>
      <:trail :if={@issue.priority in [:high, :critical]}>
        <CymphoWeb.IssueLive.Tasks.priority priority={@issue.priority} />
      </:trail>
    </.list_row>
    """
  end

  def goal_type_label(:mission), do: "Mission"
  def goal_type_label(:initiative), do: "Initiative"
  def goal_type_label(:milestone), do: "Milestone"
  def goal_type_label(_type), do: "Goal"

  # Tasks' priority bars take the issue atoms; a goal stores the word.
  def priority_atom("critical"), do: :critical
  def priority_atom("high"), do: :high
  def priority_atom(_priority), do: :medium

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
