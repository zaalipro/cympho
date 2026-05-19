defmodule Cympho.Decisions.Executor do
  @moduledoc """
  Subscribes to the global `system:decisions` topic and applies the
  side-effect for each new decision.

  Without this GenServer, decisions are decorative — they record what the
  company chose, but nothing actually changes. With it, governance choices
  become operational reality:

    * `cancel_project` — marks the named project as `:archived` and
      cancels every open issue under it.
    * `pause_engineer` — sets the named agent's `governance_status` to
      "paused" so the dispatcher stops giving them work.
    * `cancel_issue` — terminates a specific issue.

  Decision keys that don't match a known recipe are logged at debug and
  ignored — this keeps the executor permissive when new decision_keys are
  introduced before recipes are written.

  Disabled in tests via `:start_decisions_executor?` (mirrors the watchdog
  / planner / patrol pattern).
  """

  use GenServer

  alias Cympho.Agents
  alias Cympho.Decisions.Decision
  alias Cympho.Issues
  alias Cympho.Repo
  import Ecto.Query

  require Logger

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Synchronously executes the side effect for a decision. Public so tests
  can drive it without going through PubSub.
  """
  @spec execute(Decision.t()) :: :ok | {:error, term()}
  def execute(%Decision{} = decision) do
    case decision.decision_key do
      "cancel_project:" <> project_id ->
        cancel_project(project_id, decision)

      "pause_engineer:" <> agent_id ->
        pause_engineer(agent_id, decision)

      "cancel_issue:" <> issue_id ->
        cancel_issue(issue_id, decision)

      key ->
        Logger.debug(
          "[Decisions.Executor] no recipe for decision_key=#{inspect(key)}; ignoring"
        )

        :ok
    end
  end

  ## Server callbacks

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(Cympho.PubSub, "system:decisions")
    {:ok, %{}}
  end

  @impl true
  def handle_info({:decision_created, %Decision{} = decision}, state) do
    Task.Supervisor.start_child(Cympho.TaskSupervisor, fn ->
      try do
        execute(decision)
      rescue
        e ->
          Logger.warning(
            "[Decisions.Executor] error executing decision #{decision.id}: #{Exception.message(e)}"
          )
      end
    end)

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  ## Recipes

  defp cancel_project(project_id, decision) do
    case Repo.get(Cympho.Projects.Project, project_id) do
      nil ->
        :ok

      project ->
        # Cancel every open issue under the project, then mark the project
        # archived. We don't roll up via a single transaction because each
        # transition can fire its own side effects (wakes, comments).
        open_statuses = [:backlog, :todo, :in_progress, :in_review, :blocked]

        from(i in Cympho.Issues.Issue,
          where: i.project_id == ^project_id and i.status in ^open_statuses
        )
        |> Repo.all()
        |> Enum.each(fn issue ->
          {:ok, _} = Issues.transition_issue(issue, :cancelled)
        end)

        _ =
          project
          |> Cympho.Projects.Project.changeset(%{status: :archived})
          |> Repo.update()

        Logger.info(
          "[Decisions.Executor] cancel_project executed for project=#{project_id} " <>
            "decision=#{decision.id}"
        )

        :ok
    end
  end

  defp pause_engineer(agent_id, decision) do
    case Agents.get_agent(agent_id) do
      {:ok, agent} ->
        _ =
          agent
          |> Ecto.Changeset.change(%{
            governance_status: "paused",
            pause_reason: decision.reasoning || "decision-driven pause"
          })
          |> Repo.update()

        Logger.info(
          "[Decisions.Executor] pause_engineer executed for agent=#{agent_id} " <>
            "decision=#{decision.id}"
        )

        :ok

      _ ->
        :ok
    end
  end

  defp cancel_issue(issue_id, decision) do
    case Issues.get_issue(issue_id) do
      {:ok, issue} ->
        case Issues.transition_issue(issue, :cancelled) do
          {:ok, _} ->
            Logger.info(
              "[Decisions.Executor] cancel_issue executed for issue=#{issue_id} " <>
                "decision=#{decision.id}"
            )

            :ok

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        :ok
    end
  end
end
