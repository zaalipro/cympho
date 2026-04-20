defmodule Cympho.Orchestrator.Session do
  @moduledoc """
  Represents an active agent session for an issue.
  """

  @enforce_keys [:issue, :agent_id]
  defstruct [:issue, :agent_id, :session_id, turn_count: 0]

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
  a single agent session, forwarding messages to the caller via messages
  from AgentRunner.

  Protocol:
    - Started by AgentHeartbeat via `start_and_run/2`
    - Calls AgentRunner.run/4 with self() as recipient_pid
    - Receives {:session_started, session_id}, {:turn_completed, session_id, result},
      {:turn_ended_with_error, session_id, reason} from AgentRunner
    - On completion: creates Comment, transitions issue, updates agent status
  """

  use GenServer
  alias Cympho.Orchestrator.Session
  alias Cympho.{AgentRunner, AgentHeartbeat, Issues, Comments, Agents}

  @registry Cympho.OrchestratorRegistry

  @default_heartbeat_interval :timer.seconds(60)

  ## Client API

  @doc """
  Starts an orchestrator for the given issue and agent, runs the session immediately.
  Returns {:ok, pid} or {:error, reason}.
  """
  @spec start_and_run(map(), String.t()) :: {:ok, pid()} | {:error, atom()}
  def start_and_run(%{id: issue_id} = issue, agent_id) when is_binary(agent_id) do
    case Registry.lookup(@registry, issue_id) do
      [{_pid, _}] ->
        {:error, :already_started}

      [] ->
        name = via_tuple(issue_id)
        case GenServer.start_link(__MODULE__, {issue, agent_id}, name: name) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, _pid}} -> {:error, :already_started}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Returns the pid of the orchestrator for a given issue_id, or nil.
  """
  @spec whereis(String.t()) :: pid() | nil
  def whereis(issue_id) do
    case Registry.lookup(@registry, issue_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  Stops the orchestrator for a given issue_id.
  """
  @spec stop(String.t()) :: :ok
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
    session = %Session{issue: issue, agent_id: agent_id}
    {:ok, session, {:continue, :start_session}}
  end

  @impl true
  def handle_continue(:start_session, %Session{} = session) do
    issue = session.issue
    agent_id = session.agent_id

    # Use Mock for test environment, real runner otherwise
    runner = runner_module()
    session_id = runner.run(issue, agent_id, self(), run_opts(issue))

    {:noreply, %{session | session_id: session_id}}
  end

  @impl true
  def handle_info({:session_started, session_id}, %Session{} = session) do
    # AgentRunner confirmed the session started
    {:noreply, %{session | session_id: session_id}}
  end

  @impl true
  def handle_info({:turn_completed, _session_id, result}, %Session{} = session) do
    issue = session.issue
    agent_id = session.agent_id

    # Extract text content from Claude result
    body = extract_result_content(result)

    # Create comment with agent as polymorphic author
    {:ok, _comment} =
      Comments.create_comment(%{
        body: body,
        author_type: "agent",
        author_id: agent_id,
        issue_id: issue.id
      })

    # Mark issue done
    Issues.transition_issue(issue, :done)

    # Update agent status back to idle
    set_agent_idle(agent_id)

    # Stop this orchestrator - work is complete
    {:stop, :normal, session}
  end

  @impl true
  def handle_info({:turn_ended_with_error, _session_id, reason}, %Session{} = session) do
    issue = session.issue
    agent_id = session.agent_id

    # Create error comment
    error_body = "Agent work error: #{inspect(reason)}"
    {:ok, _comment} =
      Comments.create_comment(%{
        body: error_body,
        author_type: "agent",
        author_id: agent_id,
        issue_id: issue.id
      })

    # Mark issue as blocked waiting on resolution
    Issues.update_issue(issue, %{status: :blocked})

    # Keep agent idle
    set_agent_idle(agent_id)

    {:stop, :normal, session}
  end

  @impl true
  def terminate(reason, %Session{} = session) do
    _ =
      :logger.info(
        "[Orchestrator] terminated for issue #{session.issue.id}, agent #{session.agent_id}, reason: #{inspect(reason)}"
      )

    :ok
  end

  ## Private

  defp extract_result_content(result) when is_map(result) do
    content = result["content"] || []

    texts =
      content
      |> Enum.filter(fn item -> item["type"] == "text" end)
      |> Enum.map(fn item -> item["text"] end)
      |> Enum.join("\n\n")

    if texts == "",
      do: inspect(result),
      else: texts
  end

  defp extract_result_content(_), do: "No content returned"

  defp set_agent_idle(agent_id) do
    case Agents.get_agent(agent_id) do
      {:ok, agent} ->
        Agents.update_agent(agent, %{status: :idle})

      :error ->
        :error
    end
  end

  defp runner_module do
    if Application.get_env(:cympho, :env) == :test do
      Cympho.AgentRunner.Mock
    else
      Cympho.AgentRunner
    end
  end

  defp run_opts(_issue) do
    []
  end
end