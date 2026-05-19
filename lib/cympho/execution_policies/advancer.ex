defmodule Cympho.ExecutionPolicies.Advancer do
  @moduledoc """
  Subscribes to `system:execution_policies` and auto-advances stages whose
  next-stage config carries `"auto_advance": true`.

  The advancer keeps the existing human-driven
  `Cympho.Issues.execution_policy_decision/3` path working unchanged: it
  only fires when, after a stage is approved, the *new current* stage's
  config opts in.

  ## Events emitted

    * `[:cympho, :execution_policy, :advanced]` — `%{stage_name: string,
      outcome: string}` metadata
    * `[:cympho, :execution_policy, :completed]` — when the terminal
      stage finishes

  Gated by `:cympho, :start_execution_policy_advancer?` so tests can
  opt out the same way `Decisions.Executor` does.
  """

  use GenServer

  require Logger

  alias Cympho.Issues
  alias Cympho.Issues.Issue
  alias Cympho.Issues.ExecutionState
  alias Cympho.ExecutionPolicies.ExecutionPolicy

  @system_topic "system:execution_policies"

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Synchronously evaluates the auto-advance recipe for a stage_completed
  payload. Public so tests can drive it without going through PubSub.

  Returns `:ok`, `:noop`, or `{:error, reason}`.
  """
  @spec advance_now(map(), keyword()) ::
          :ok | :noop | {:error, term()}
  def advance_now(%{transition: :final, policy: policy, issue: issue}, _opts) do
    :telemetry.execute(
      [:cympho, :execution_policy, :completed],
      %{count: 1},
      %{issue_id: issue.id, policy_id: policy.id}
    )

    :ok
  end

  def advance_now(%{issue: %Issue{} = issue, policy: %ExecutionPolicy{} = policy}, _opts) do
    state = ExecutionState.normalize(issue.execution_state)
    issue = %{issue | execution_state: state}

    case current_stage_config(state, policy) do
      nil ->
        Logger.warning(
          "[ExecutionPolicies.Advancer] missing stage config for issue=#{issue.id} " <>
            "stage_index=#{inspect(state[:current_stage_index])}; leaving pending"
        )

        :noop

      %{} = config ->
        if auto_advance?(config) do
          decided_by = state.current_participant || ExecutionState.original_executor(state)

          if is_nil(decided_by) do
            Logger.warning(
              "[ExecutionPolicies.Advancer] no participant to auto-approve issue=#{issue.id}"
            )

            :noop
          else
            do_auto_advance(issue, policy, config, decided_by)
          end
        else
          :noop
        end

      _ ->
        Logger.warning(
          "[ExecutionPolicies.Advancer] malformed stage_configs for issue=#{issue.id}; leaving pending"
        )

        :noop
    end
  rescue
    e ->
      Logger.warning(
        "[ExecutionPolicies.Advancer] crash for issue=#{Map.get(payload_issue(issue), :id)}: " <>
          Exception.message(e)
      )

      {:error, e}
  end

  def advance_now(_payload, _opts), do: :noop

  defp payload_issue(%Issue{} = i), do: i
  defp payload_issue(_), do: %{id: nil}

  defp do_auto_advance(%Issue{} = issue, %ExecutionPolicy{} = policy, config, decided_by) do
    case Issues.execution_policy_decision(issue, :approve, decided_by) do
      {:ok, updated} ->
        :telemetry.execute(
          [:cympho, :execution_policy, :advanced],
          %{count: 1},
          %{
            stage_name: stage_name(config),
            outcome: "approved",
            issue_id: updated.id,
            policy_id: policy.id
          }
        )

        if updated.company_id do
          Phoenix.PubSub.broadcast(
            Cympho.PubSub,
            "company:#{updated.company_id}:execution_policies",
            {:stage_advanced, %{issue: updated, policy: policy, stage_name: stage_name(config)}}
          )
        end

        :ok

      {:error, reason} ->
        Logger.warning(
          "[ExecutionPolicies.Advancer] auto-advance failed issue=#{issue.id} " <>
            "reason=#{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp auto_advance?(config) when is_map(config) do
    val =
      Map.get(config, "auto_advance") ||
        Map.get(config, :auto_advance)

    val in [true, "true"]
  end

  defp auto_advance?(_), do: false

  defp stage_name(config) when is_map(config) do
    (Map.get(config, "name") || Map.get(config, :name) || "stage") |> to_string()
  end

  defp current_stage_config(%{current_stage_index: index}, %ExecutionPolicy{
         stage_configs: configs
       })
       when is_integer(index) and is_list(configs) do
    Enum.at(configs, index)
  end

  defp current_stage_config(_, _), do: nil

  ## Server callbacks

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(Cympho.PubSub, @system_topic)
    {:ok, %{}}
  end

  @impl true
  def handle_info({:stage_completed, payload}, state) do
    Task.Supervisor.start_child(Cympho.TaskSupervisor, fn ->
      try do
        advance_now(payload, [])
      rescue
        e ->
          Logger.warning("[ExecutionPolicies.Advancer] task crash: #{Exception.message(e)}")
      end
    end)

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
