defmodule Cympho.Orchestrator.Session do
  @moduledoc """
  Represents an active agent session for an issue.
  """

  @enforce_keys [:issue, :agent_id]
  defstruct [:issue, :agent_id, :session_id, :turn_count]

  @type t :: %__MODULE__{
          issue: map(),
          agent_id: String.t(),
          session_id: reference() | nil,
          turn_count: non_neg_integer()
        }
end

defmodule Cympho.Orchestrator do
  @moduledoc """
  Orchestrates agent sessions for issue processing.

  Each orchestrator instance is registered by issue_id and manages
  a single agent session, forwarding messages to the caller.
  """

  use GenServer
  alias Cympho.Orchestrator.Session

  @registry Cympho.OrchestratorRegistry

  ## Client API

  @doc """
  Starts an orchestrator for the given issue and agent.
  """
  def start_link(%{id: issue_id} = issue, agent_id) do
    name = via_tuple(issue_id)
    GenServer.start_link(__MODULE__, {issue, agent_id}, name: name)
  end

  @doc """
  Returns the pid of the orchestrator for a given issue_id, or nil.
  """
  def whereis(issue_id) do
    case Registry.lookup(@registry, issue_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  Stops the orchestrator for a given issue_id.
  """
  def stop(issue_id) do
    case whereis(issue_id) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end
  end

  defp via_tuple(issue_id) do
    {:via, Registry, {@registry, issue_id}}
  end

  ## Server Callbacks

  @impl true
  def init({issue, agent_id}) do
    {:ok, %Session{issue: issue, agent_id: agent_id}}
  end

  @impl true
  def handle_continue(:start_session, %Session{} = session) do
    {:noreply, session}
  end

  @impl true
  def handle_info(msg, %Session{} = session) do
    {:noreply, session}
  end
end
