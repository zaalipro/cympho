defmodule Cympho.Issues.ExecutionState do
  @moduledoc """
  Manages execution state for issues with execution policies.

  Execution state tracks the current stage, participant, and decision history
  as an issue flows through an execution policy's stages.
  """

  alias Cympho.ExecutionPolicies.ExecutionPolicy

  @type stage_type :: :executor | :reviewer | :approver
  @type decision :: :approved | :changes_requested | :escalated

  @type t :: %{
          current_stage_index: non_neg_integer(),
          current_stage_type: stage_type(),
          current_participant: binary() | nil,
          return_assignee: binary() | nil,
          last_decision_outcome: decision() | nil,
          history: [map()]
        }

  @doc """
  Initializes execution state for an issue with a given execution policy.
  Sets the first stage as the current stage.
  """
  @spec initialize(ExecutionPolicy.t(), binary()) :: t() | nil
  def initialize(%ExecutionPolicy{stage_configs: stage_configs}, executor_id)
      when is_list(stage_configs) and length(stage_configs) > 0 do
    first_stage = hd(stage_configs)

    %{
      current_stage_index: 0,
      current_stage_type: stage_type(first_stage),
      current_participant: executor_id,
      return_assignee: nil,
      last_decision_outcome: nil,
      history: []
    }
  end

  def initialize(_, _), do: nil

  @doc """
  Advances to the next stage in the execution policy.
  Returns {:ok, updated_state} or {:done, state} if all stages are complete.
  """
  @spec advance(t(), ExecutionPolicy.t(), binary() | nil) ::
          {:ok, t()} | {:done, t()}
  def advance(state, %ExecutionPolicy{stage_configs: stage_configs}, decided_by) do
    current_index = state.current_stage_index
    next_index = current_index + 1

    history_entry = %{
      stage_index: current_index,
      stage_type: state.current_stage_type,
      participant: decided_by,
      decision: state.last_decision_outcome,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    updated_history = state.history ++ [history_entry]

    if next_index >= length(stage_configs) do
      {:done, %{state | history: updated_history, last_decision_outcome: :approved}}
    else
      next_stage = Enum.at(stage_configs, next_index)
      next_participant = get_participant_id(next_stage)

      updated = %{
        state
        | current_stage_index: next_index,
          current_stage_type: stage_type(next_stage),
          current_participant: next_participant,
          return_assignee: state.current_participant,
          last_decision_outcome: nil,
          history: updated_history
      }

      {:ok, updated}
    end
  end

  @doc """
  Records a changes_requested decision, returning the issue to the return_assignee.
  """
  @spec request_changes(t(), binary()) :: t()
  def request_changes(state, decided_by) do
    history_entry = %{
      stage_index: state.current_stage_index,
      stage_type: state.current_stage_type,
      participant: decided_by,
      decision: :changes_requested,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    %{
      state
      | current_participant: state.return_assignee,
        last_decision_outcome: :changes_requested,
        history: state.history ++ [history_entry]
    }
  end

  @doc """
  Records an approval decision at the current stage.
  """
  @spec approve(t(), binary()) :: t()
  def approve(state, decided_by) do
    %{state | last_decision_outcome: :approved, current_participant: decided_by}
  end

  @doc """
  Escalates to a higher authority when the current participant is unavailable.
  """
  @spec escalate(t(), binary()) :: t()
  def escalate(state, escalated_to) do
    history_entry = %{
      stage_index: state.current_stage_index,
      stage_type: state.current_stage_type,
      participant: nil,
      decision: :escalated,
      escalated_to: escalated_to,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    %{
      state
      | current_participant: escalated_to,
        last_decision_outcome: :escalated,
        history: state.history ++ [history_entry]
    }
  end

  @doc """
  Gets the stage type for a given stage config.
  """
  @spec stage_type(map()) :: stage_type()
  def stage_type(config) when is_map(config) do
    type = Map.get(config, "type") || Map.get(config, :type)
    if is_binary(type), do: String.to_existing_atom(type), else: type
  end

  @doc """
  Gets the participant ID from a stage config.
  """
  @spec get_participant_id(map()) :: binary() | nil
  def get_participant_id(config) when is_map(config) do
    Map.get(config, "participant_id") || Map.get(config, :participant_id)
  end

  @doc """
  Determines the status an issue should transition to based on the current stage type
  and the decision being made.
  """
  @spec target_status(stage_type(), :approve | :request_changes) :: atom()
  def target_status(:executor, :approve), do: :in_review
  def target_status(:reviewer, :approve), do: :in_review
  def target_status(:reviewer, :request_changes), do: :in_progress
  def target_status(:approver, :approve), do: :done
  def target_status(:approver, :request_changes), do: :in_progress
  def target_status(_, :approve), do: :in_review
  def target_status(_, :request_changes), do: :in_progress

  @doc """
  Checks if execution state is active (issue has a policy and is mid-flow).
  """
  @spec active?(map() | nil) :: boolean()
  def active?(nil), do: false
  def active?(%{current_stage_index: _}), do: true
  def active?(_), do: false

  @doc """
  Returns the stage config for the current stage from the policy.
  """
  @spec current_stage_config(t(), ExecutionPolicy.t()) :: map() | nil
  def current_stage_config(%{current_stage_index: index}, %ExecutionPolicy{stage_configs: configs}) do
    Enum.at(configs, index)
  end

  def current_stage_config(_, _), do: nil

  @doc """
  Returns true if the current stage requires a different actor than the executor.
  """
  @spec require_different_actor?(t(), ExecutionPolicy.t()) :: boolean()
  def require_different_actor?(state, policy) do
    case current_stage_config(state, policy) do
      nil -> false
      config -> flag_enabled?(config, "require_different_actor")
    end
  end

  @doc """
  Returns true if the current stage requires a human (non-agent) approver.
  """
  @spec require_human?(t(), ExecutionPolicy.t()) :: boolean()
  def require_human?(state, policy) do
    case current_stage_config(state, policy) do
      nil -> false
      config -> flag_enabled?(config, "require_human")
    end
  end

  @doc """
  Returns true if the current stage has been approved.
  """
  @spec stage_complete?(t()) :: boolean()
  def stage_complete?(%{last_decision_outcome: :approved}), do: true
  def stage_complete?(_), do: false

  @doc """
  Returns the original executor — the return_assignee when available,
  falling back to the current participant.
  """
  @spec original_executor(t()) :: binary() | nil
  def original_executor(%{return_assignee: assignee}) when is_binary(assignee), do: assignee
  def original_executor(%{current_participant: participant}), do: participant
  def original_executor(_), do: nil

  defp flag_enabled?(config, key) do
    value = Map.get(config, key) || Map.get(config, String.to_atom(key))
    value in [true, "true"]
  end
end
