defmodule Cympho.RuntimeContext do
  @moduledoc """
  Immutable context assembled before an autonomous agent run.

  This keeps runtime concerns out of prompts and board state: adapter selection,
  workspace paths, resolved secrets, and budget state are prepared once and then
  passed through to the adapter.
  """

  @enforce_keys [:issue_id, :agent_id, :adapter, :adapter_config, :cwd]
  defstruct [
    :run_id,
    :company_id,
    :project_id,
    :goal_id,
    :issue_id,
    :agent_id,
    :adapter,
    :adapter_config,
    :project_workspace,
    :execution_workspace,
    :cwd,
    env: %{},
    skills: [],
    budget: %{},
    metadata: %{}
  ]

  @type t :: %__MODULE__{}
end
