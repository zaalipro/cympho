defmodule Cympho.AgentRunner.Mock do
  @moduledoc """
  Mock implementation of AgentRunner for testing without spawning Claude CLI.

  Delegates to `Cympho.AgentAdapters.MockAdapter` which implements the
  `Cympho.AgentAdapters.Adapter` behaviour. This module exists as a
  backwards-compatible shim consumed by the orchestrator's `runner_module/0`.
  """

  @behaviour Cympho.AgentAdapters.Adapter

  alias Cympho.AgentAdapters.MockAdapter

  @impl true
  def type, do: MockAdapter.type()

  @impl true
  def available?(config), do: MockAdapter.available?(config)

  @impl true
  def health_check(config), do: MockAdapter.health_check(config)

  @impl true
  def validate_config(config), do: MockAdapter.validate_config(config)

  @impl true
  defdelegate run(issue, agent_id, recipient_pid, opts), to: MockAdapter

  @doc """
  Simulates a session that errors immediately.
  """
  defdelegate run_with_error(issue, agent_id, recipient_pid, error_reason \\ :mock_error),
    to: MockAdapter
end
