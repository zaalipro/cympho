defmodule Cympho.Agents do
  @moduledoc """
  The Agents context manages agent entities and their lifecycle.
  """

  import Ecto.Query, warn: false
  alias Cympho.Repo
  alias Cympho.Agents.Agent
  alias Cympho.Agents.AgentConfigRevision
  alias Cympho.BoardApprovals
  alias Cympho.Issues.Issue

  @doc """
  Returns the list of all agents.
  """
  def list_agents do
    Repo.all(Agent)
  end

  @doc """
  Returns agents belonging to a company.
  """
  def list_agents_by_company(company_id) do
    Agent
    |> where(company_id: ^company_id)
    |> Repo.all()
  end

  @doc """
  Returns agents with the specified role.
  """
  def list_agents_by_role(role) when is_atom(role) do
    Agent
    |> where(role: ^role)
    |> Repo.all()
  end

  @doc """
  Returns agents with the specified status.
  """
  def list_agents_by_status(status) when is_atom(status) do
    Agent
    |> where(status: ^status)
    |> Repo.all()
  end

  @doc """
  Returns agents with the specified adapter type.
  """
  def list_agents_by_adapter(adapter) when is_atom(adapter) do
    Agent
    |> where(adapter: ^adapter)
    |> Repo.all()
  end

  @doc """
  Returns the list of valid adapter types.
  """
  def adapter_options, do: Agent.adapter_options()

  @doc """
  Gets a single agent by id.
  """
  def get_agent!(id), do: Repo.get!(Agent, id)

  @doc """
  Gets a single agent by id, returns {:ok, agent} or {:error, :not_found}.
  """
  def get_agent(id) do
    case Repo.get(Agent, id) do
      nil -> {:error, :not_found}
      agent -> {:ok, agent}
    end
  end

  @doc """
  Creates an agent.
  If governance requires approval for agent_hire, creates a BoardApproval instead
  and returns `{:error, :pending_board_approval, approval_id}`.
  """
  def create_agent(attrs \\ %{}) do
    with :ok <- maybe_require_hire_approval(attrs) do
      do_create_agent(attrs)
    end
  end

  def do_create_agent(attrs) do
    %Agent{}
    |> Agent.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, agent} ->
        Phoenix.PubSub.broadcast(Cympho.PubSub, "agents", {:agent_created, agent})
        {:ok, agent}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Updates an agent.
  If the role is changing and governance requires approval, creates a BoardApproval
  and returns `{:error, :pending_board_approval, approval_id}`.
  """
  def update_agent(%Agent{} = agent, attrs) do
    with :ok <- maybe_require_role_change_approval(agent, attrs) do
      do_update_agent(agent, attrs)
    end
  end

  def do_update_agent(agent, attrs) do
    agent
    |> Agent.changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        Phoenix.PubSub.broadcast(Cympho.PubSub, "agents", {:agent_updated, updated})
        {:ok, updated}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Updates an agent by ID, returns {:ok, agent} or {:error, reason}.
  """
  def update_agent_by_id(agent_id, attrs) when is_binary(agent_id) do
    case get_agent(agent_id) do
      {:ok, agent} -> update_agent(agent, attrs)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Deletes an agent.
  """
  def delete_agent(%Agent{} = agent) do
    Repo.delete(agent)
    |> case do
      {:ok, _} ->
        Phoenix.PubSub.broadcast(Cympho.PubSub, "agents", {:agent_deleted, agent.id})
        {:ok, agent}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Returns a changeset for creating or updating an agent.
  """
  def change_agent(%Agent{} = agent, attrs \\ %{}) do
    Agent.changeset(agent, attrs)
  end

  @doc """
  Subscribes to agent updates.
  """
  def subscribe do
    Phoenix.PubSub.subscribe(Cympho.PubSub, "agents")
  end

  @doc """
  Gets an idle agent by role, or nil if none available.
  """
  def get_idle_agent_by_role(role) do
    Agent
    |> where(role: ^role, status: :idle)
    |> first()
    |> Repo.one()
  end

  @doc """
  Returns agents eligible for dispatch: matching role, not in :error status,
  and not at max_concurrent_jobs capacity.
  """
  @spec list_eligible_agents(:ceo | :cto | :engineer) :: [Agent.t()]
  def list_eligible_agents(role) when is_atom(role) do
    Agent
    |> where(role: ^role, status: :idle)
    |> Repo.all()
    |> Enum.reject(&is_agent_at_capacity?/1)
  end

  @doc """
  Counts the number of :in_progress issues assigned to an agent.
  """
  @spec count_active_assignments(String.t()) :: non_neg_integer()
  def count_active_assignments(agent_id) when is_binary(agent_id) do
    Repo.one(
      from(i in Issue,
        where: i.assignee_id == ^agent_id and i.status == :in_progress,
        select: count(i.id)
      )
    ) || 0
  end

  @doc """
  Counts the number of running jobs for an agent.
  """
  @spec count_running_jobs(String.t()) :: non_neg_integer()
  def count_running_jobs(agent_id) when is_binary(agent_id) do
    Repo.one(
      from(i in Issue,
        where: i.assignee_id == ^agent_id and i.status == :in_progress,
        select: count(i.id)
      )
    ) || 0
  end

  @doc """
  Returns true if the agent is at or above their max_concurrent_jobs limit.
  """
  @spec is_agent_at_capacity?(String.t() | Agent.t()) :: boolean()
  def is_agent_at_capacity?(%Agent{} = agent) do
    running = count_running_jobs(agent.id)
    running >= agent.max_concurrent_jobs
  end

  def is_agent_at_capacity?(agent_id) when is_binary(agent_id) do
    case get_agent(agent_id) do
      {:ok, agent} ->
        running = count_running_jobs(agent_id)
        running >= agent.max_concurrent_jobs

      {:error, _} ->
        true
    end
  end

  @doc """
  Gets an agent by its url_key field, returns {:ok, agent} or {:error, :not_found}.
  """
  def get_agent_by_url_key(url_key) when is_binary(url_key) do
    Repo.one(from a in Agent, where: a.url_key == ^url_key)
    |> case do
      nil -> {:error, :not_found}
      agent -> {:ok, agent}
    end
  end

  @doc """
  Role hierarchy rank: higher rank = more authority.
  Order: designer(1) < product_manager(2) < engineer(3) < cto(4) < ceo(5)
  """
  @spec role_rank(:designer | :product_manager | :engineer | :cto | :ceo) :: non_neg_integer()
  def role_rank(:designer), do: 1
  def role_rank(:product_manager), do: 2
  def role_rank(:engineer), do: 3
  def role_rank(:cto), do: 4
  def role_rank(:ceo), do: 5

  @doc """
  Returns true if parent_agent can spawn an agent with child_role.
  Parent must have role_rank >= child_rank (allows peer spawning for redundancy).
  """
  @spec spawn_authorized?(Agent.t(), :designer | :product_manager | :engineer | :cto | :ceo) ::
          boolean()
  def spawn_authorized?(%Agent{} = parent_agent, child_role) do
    role_rank(parent_agent.role) >= role_rank(child_role)
  end

  @doc """
  Returns the list of roles that the given agent is authorized to spawn.
  """
  @spec spawnable_roles(Agent.t()) :: [
          :designer | :product_manager | :engineer | :cto | :ceo,
          ...
        ]
  def spawnable_roles(%Agent{} = parent_agent) do
    parent_rank = role_rank(parent_agent.role)

    [:designer, :product_manager, :engineer, :cto, :ceo]
    |> Enum.filter(fn role -> role_rank(role) <= parent_rank end)
  end

  @doc """
  Spawns a new agent: creates the agent record and starts its heartbeat process.
  If governance requires approval for agent_hire, creates a BoardApproval instead
  and returns `{:error, :pending_board_approval, approval_id}`.
  Returns {:ok, agent} or {:error, reason}.
  """
  @spec spawn_agent(map(), String.t()) ::
          {:ok, Agent.t()}
          | {:error, Ecto.Changeset.t() | atom()}
          | {:error, :pending_board_approval, String.t()}
  def spawn_agent(attrs \\ %{}, parent_agent_id) when is_binary(parent_agent_id) do
    with {:ok, parent_agent} <- get_agent(parent_agent_id),
         {:ok, child_attrs} <- validate_spawn(parent_agent, attrs),
         :ok <- maybe_require_spawn_hire_approval(parent_agent, child_attrs) do
      child_attrs_with_creator = Map.put(child_attrs, :created_by_agent_id, parent_agent_id)
      execute_spawn(child_attrs_with_creator)
    end
  end

  defp validate_spawn(%Agent{} = parent_agent, attrs) do
    case attrs do
      %{role: child_role} when is_atom(child_role) ->
        if spawn_authorized?(parent_agent, child_role) do
          {:ok, attrs}
        else
          {:error, :unauthorized_spawn}
        end

      _ ->
        {:error, :missing_role}
    end
  end

  defp execute_spawn(attrs) do
    case do_create_agent(attrs) do
      {:ok, agent} ->
        case Cympho.AgentHeartbeat.start_for_agent(agent.id) do
          {:ok, _pid} ->
            {:ok, agent}

          {:error, reason} ->
            Repo.delete(agent)
            {:error, reason}
        end

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Executes a pending agent hire after board approval.
  Called by BoardApprovalActionExecutor.
  """
  def execute_approved_hire(proposal_data) do
    attrs = proposal_data["attrs"] || %{}
    parent_agent_id = proposal_data["parent_agent_id"]

    child_attrs =
      if parent_agent_id do
        Map.put(attrs, :created_by_agent_id, parent_agent_id)
      else
        attrs
      end

    execute_spawn(child_attrs)
  end

  @doc """
  Applies a role change directly, bypassing governance checks.
  Called by BoardApprovalActionExecutor when an approval is granted.
  """
  def apply_role_change(agent_id, new_role) when is_binary(agent_id) do
    with {:ok, agent} <- get_agent(agent_id) do
      do_update_agent(agent, %{role: new_role})
    end
  end

  # Governance check helpers

  defp maybe_require_hire_approval(attrs) do
    company_id = get_company_id(attrs)

    if company_id && BoardApprovals.governance_required?(company_id, "agent_hire") do
      create_hire_approval(company_id, nil, attrs)
    else
      :ok
    end
  end

  defp maybe_require_spawn_hire_approval(%Agent{company_id: nil}, _attrs), do: :ok

  defp maybe_require_spawn_hire_approval(%Agent{} = parent_agent, attrs) do
    if BoardApprovals.governance_required?(parent_agent.company_id, "agent_hire") do
      create_hire_approval(parent_agent.company_id, parent_agent.id, attrs)
    else
      :ok
    end
  end

  defp create_hire_approval(company_id, requester_agent_id, attrs) do
    role = attrs[:role] || attrs["role"]
    name = attrs[:name] || attrs["name"] || "Unnamed Agent"

    approval_attrs = %{
      title: "Agent Hire: #{name} (#{role})",
      description: "Request to hire new agent '#{name}' with role '#{role}'.",
      category: "agent_hire",
      company_id: company_id,
      proposal_data: %{
        "attrs" => stringify_map_keys(attrs),
        "parent_agent_id" => requester_agent_id
      },
      review_deadline: default_review_deadline()
    }

    {approval_attrs, actor} =
      if requester_agent_id do
        {Map.put(approval_attrs, :requested_by_agent_id, requester_agent_id),
         %Agent{id: requester_agent_id}}
      else
        {approval_attrs, {"system", company_id}}
      end

    case BoardApprovals.create_board_approval(approval_attrs, actor) do
      {:ok, approval} -> {:error, :pending_board_approval, approval.id}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp maybe_require_role_change_approval(%Agent{} = agent, attrs) do
    new_role = extract_role(attrs)

    if new_role && new_role != agent.role && agent.company_id &&
         BoardApprovals.governance_required?(agent.company_id, "agent_promotion") do
      create_role_change_approval(agent, new_role)
    else
      :ok
    end
  end

  defp create_role_change_approval(%Agent{} = agent, new_role) do
    approval_attrs = %{
      title: "Agent Role Change: #{agent.name} (#{agent.role} → #{new_role})",
      description: "Request to change agent '#{agent.name}' role from '#{agent.role}' to '#{new_role}'.",
      category: "agent_promotion",
      company_id: agent.company_id,
      requested_by_agent_id: agent.id,
      proposal_data: %{
        "agent_id" => agent.id,
        "current_role" => to_string(agent.role),
        "new_role" => to_string(new_role)
      },
      review_deadline: default_review_deadline()
    }

    case BoardApprovals.create_board_approval(approval_attrs, agent) do
      {:ok, approval} -> {:error, :pending_board_approval, approval.id}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp extract_role(attrs) when is_map(attrs) do
    case attrs[:role] || attrs["role"] do
      nil -> nil
      role when is_atom(role) -> role
      role when is_binary(role) -> String.to_existing_atom(role)
    end
  end

  defp get_company_id(attrs) when is_map(attrs) do
    attrs[:company_id] || attrs["company_id"]
  end

  defp default_review_deadline do
    DateTime.add(DateTime.utc_now(), 7 * 24 * 3600, :second)
  end

  defp stringify_map_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  @doc """
  Returns the inbox for an agent: issues assigned to them, sorted by priority (high first)
  then by insertion date (oldest first). Returns compact maps with id, title, status, priority.
  """
  def list_agent_inbox(agent_id) when is_binary(agent_id) do
    from(i in Issue,
      where:
        i.assignee_id == ^agent_id and i.status in [:todo, :in_progress, :in_review, :blocked],
      select: %{
        id: i.id,
        title: i.title,
        status: i.status,
        priority: i.priority,
        assignee_id: i.assignee_id
      },
      order_by: [
        fragment(
          "CASE ? WHEN 'high' THEN 0 WHEN 'medium' THEN 1 WHEN 'low' THEN 2 ELSE 3 END",
          i.priority
        ),
        asc: i.inserted_at
      ]
    )
    |> Repo.all()
  end

  @doc """
  Updates an agent's own status and last_heartbeat_at.
  Uses the restricted status_changeset that only allows status and last_heartbeat_at.
  """
  def update_agent_status(%Agent{} = agent, attrs) do
    agent
    |> Agent.status_changeset(Map.put(attrs, "last_heartbeat_at", DateTime.utc_now()))
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        Phoenix.PubSub.broadcast(Cympho.PubSub, "agents", {:agent_updated, updated})
        {:ok, updated}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Returns a map with counts of agents by status.
  """
  @spec count_by_status() :: %{
          idle: non_neg_integer(),
          running: non_neg_integer(),
          error: non_neg_integer(),
          sleeping: non_neg_integer(),
          offline: non_neg_integer()
        }
  def count_by_status do
    from(a in Agent,
      group_by: a.status,
      select: {a.status, count(a.id)}
    )
    |> Repo.all()
    |> Enum.into(%{idle: 0, running: 0, error: 0, sleeping: 0, offline: 0})
  end

  @doc """
  Returns session progress for a running agent.
  Gets current issue, turn count, and elapsed time from AgentHeartbeat and Orchestrator.
  """
  @spec get_session_progress(String.t()) :: {:ok, map()} | {:error, :not_running}
  def get_session_progress(agent_id) when is_binary(agent_id) do
    case Cympho.AgentHeartbeat.status(agent_id) do
      {:ok, :running} ->
        heartbeat_state = get_heartbeat_state(agent_id)
        issue_id = heartbeat_state[:current_issue_id]

        issue_info =
          if issue_id do
            case Repo.get(Issue, issue_id) do
              nil -> nil
              issue -> %{id: issue.id, title: issue.title, identifier: issue.identifier}
            end
          else
            nil
          end

        orchestrator_info = get_orchestrator_info(issue_id)

        {:ok,
         %{
           agent_id: agent_id,
           issue: issue_info,
           turn_count: orchestrator_info[:turn_count] || 0,
           started_at: heartbeat_state[:started_at],
           elapsed_seconds: calculate_elapsed(heartbeat_state[:started_at])
         }}

      {:ok, _} ->
        {:error, :not_running}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_heartbeat_state(agent_id) do
    case Cympho.AgentHeartbeat.Registry.lookup(agent_id) do
      {:ok, pid} ->
        try do
          GenServer.call(pid, :get_state, 5000)
        catch
          :exit, _ -> %{status: :unknown}
        end

      :error ->
        %{status: :unknown}
    end
  end

  defp get_orchestrator_info(nil), do: %{turn_count: 0}

  defp get_orchestrator_info(issue_id) do
    case Cympho.Orchestrator.get_session_state(issue_id) do
      nil -> %{turn_count: 0}
      state -> %{turn_count: state[:turn_count]}
    end
  end

  defp calculate_elapsed(nil), do: 0

  defp calculate_elapsed(started_at) do
    DateTime.diff(DateTime.utc_now(), started_at, :second)
  end

  @doc """
  Kills the running session for an agent.
  Stops the Orchestrator session gracefully and resets agent to idle.
  """
  @spec kill_session(String.t()) :: :ok | {:error, :not_running | :not_found}
  def kill_session(agent_id) when is_binary(agent_id) do
    case Cympho.AgentHeartbeat.status(agent_id) do
      {:ok, :running} ->
        heartbeat_state = get_heartbeat_state(agent_id)
        issue_id = heartbeat_state[:current_issue_id]

        if issue_id do
          Cympho.Orchestrator.stop(issue_id)
        end

        _ = Cympho.AgentHeartbeat.set_idle(agent_id)

        case get_agent(agent_id) do
          {:ok, agent} ->
            update_agent(agent, %{status: :idle})

          {:error, _} ->
            :error
        end

        :ok

      {:ok, _} ->
        {:error, :not_running}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns all agents with their parent and children preloaded.
  """
  def list_agents_with_hierarchy do
    Agent
    |> preload([:parent, :children])
    |> Repo.all()
  end

  @doc """
  Returns the org chart as a tree structure starting from root agents (no parent).
  """
  def get_org_chart do
    roots =
      Agent
      |> where([a], is_nil(a.parent_id))
      |> preload([:children])
      |> Repo.all()

    build_org_tree(roots)
  end

  defp build_org_tree(agents) when is_list(agents) do
    Enum.map(agents, &build_org_tree/1)
  end

  defp build_org_tree(%Agent{} = agent) do
    agent_with_children =
      Agent
      |> where([a], a.id == ^agent.id)
      |> preload([:children, children: [:children]])
      |> Repo.one()

    %{
      id: agent_with_children.id,
      name: agent_with_children.name,
      title: agent_with_children.title,
      role: agent_with_children.role,
      status: agent_with_children.status,
      adapter: agent_with_children.adapter,
      children: build_org_tree(agent_with_children.children)
    }
  end

  @doc """
  Returns all children of an agent (direct reports).
  """
  def list_children(agent_id) when is_binary(agent_id) do
    Agent
    |> where([a], a.parent_id == ^agent_id)
    |> Repo.all()
  end

  @doc """
  Returns the parent of an agent.
  """
  def get_parent(agent_id) when is_binary(agent_id) do
    case Repo.get(Agent, agent_id) do
      nil -> {:error, :not_found}
      %{parent: nil} -> {:ok, nil}
      %{parent: parent} -> {:ok, parent}
    end
  end

  @doc """
  Returns all ancestors of an agent (parent chain to root).
  """
  def get_ancestors(agent_id) when is_binary(agent_id) do
    case get_agent(agent_id) do
      {:error, _} -> []
      {:ok, agent} -> build_ancestors(agent)
    end
  end

  defp build_ancestors(nil), do: []

  defp build_ancestors(%Agent{parent: nil}), do: []

  defp build_ancestors(%Agent{parent: parent} = agent) do
    [parent | build_ancestors(parent)]
  end

  @doc """
  Returns all descendants of an agent (all children, grandchildren, etc.).
  """
  def get_descendants(agent_id) when is_binary(agent_id) do
    case get_agent(agent_id) do
      {:error, _} -> []
      {:ok, agent} -> build_descendants(agent)
    end
  end

  defp build_descendants(%Agent{} = agent) do
    children =
      Agent
      |> where([a], a.parent_id == ^agent.id)
      |> Repo.all()

    children ++ Enum.flat_map(children, &build_descendants/1)
  end

  @doc """
  Pauses an agent by setting status to :sleeping.
  """
  def pause_agent(%Agent{} = agent) do
    update_agent(agent, %{status: :sleeping})
  end

  def pause_agent(agent_id) when is_binary(agent_id) do
    case get_agent(agent_id) do
      {:ok, agent} -> pause_agent(agent)
      error -> error
    end
  end

  @doc """
  Resumes a sleeping agent by setting status to :idle.
  """
  def resume_agent(%Agent{} = agent) do
    update_agent(agent, %{status: :idle})
  end

  def resume_agent(agent_id) when is_binary(agent_id) do
    case get_agent(agent_id) do
      {:ok, agent} -> resume_agent(agent)
      error -> error
    end
  end

  @doc """
  Terminates an agent by setting status to :offline.
  """
  def terminate_agent(%Agent{} = agent) do
    case agent.status do
      :running ->
        case kill_session(agent.id) do
          :ok -> update_agent(agent, %{status: :offline})
          error -> error
        end

      _ ->
        update_agent(agent, %{status: :offline})
    end
  end

  def terminate_agent(agent_id) when is_binary(agent_id) do
    case get_agent(agent_id) do
      {:ok, agent} -> terminate_agent(agent)
      error -> error
    end
  end

  @doc """
  Returns all config revisions for an agent, ordered by version (newest first).
  """
  def list_config_revisions(agent_id) when is_binary(agent_id) do
    AgentConfigRevision
    |> where(agent_id: ^agent_id)
    |> order_by(desc: :version)
    |> Repo.all()
  end

  @doc """
  Gets the latest config revision for an agent.
  """
  def get_latest_config_revision(agent_id) when is_binary(agent_id) do
    AgentConfigRevision
    |> where(agent_id: ^agent_id)
    |> order_by(desc: :version)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Creates a new config revision for an agent.
  Automatically increments the version number.
  """
  def create_config_revision(agent_id, attrs \\ %{}) do
    latest_version =
      get_latest_version_number(agent_id)

    new_attrs =
      attrs
      |> Map.put(:agent_id, agent_id)
      |> Map.put(:version, latest_version + 1)

    %AgentConfigRevision{}
    |> AgentConfigRevision.changeset(new_attrs)
    |> Repo.insert()
  end

  @doc """
  Gets the current version number for an agent's config revisions.
  Returns 0 if no revisions exist.
  """
  def get_latest_version_number(agent_id) when is_binary(agent_id) do
    case get_latest_config_revision(agent_id) do
      nil -> 0
      revision -> revision.version
    end
  end

  @doc """
  Restores an agent to a specific config revision.
  Creates a new revision with the restored content.
  """
  def restore_config_revision(agent_id, revision_id) do
    case Repo.get(AgentConfigRevision, revision_id) do
      nil ->
        {:error, :not_found}

      revision ->
        case get_agent(agent_id) do
          {:ok, agent} ->
            attrs = %{
              instructions: revision.instructions,
              config: revision.config
            }

            with {:ok, _new_revision} <- create_config_revision(agent_id, attrs),
                 {:ok, _updated_agent} <- update_agent(agent, attrs) do
              {:ok, agent}
            end

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc """
  Compares two config revisions and returns the differences.
  """
  def compare_config_revisions(revision1_id, revision2_id) do
    revision1 = Repo.get(AgentConfigRevision, revision1_id)
    revision2 = Repo.get(AgentConfigRevision, revision2_id)

    cond do
      is_nil(revision1) or is_nil(revision2) ->
        {:error, :not_found}

      true ->
        %{
          instructions_diff: compare_text(revision1.instructions, revision2.instructions),
          config_diff: compare_maps(revision1.config, revision2.config)
        }
    end
  end

  defp compare_text(nil, nil), do: :unchanged
  defp compare_text(text1, text2) when text1 == text2, do: :unchanged
  defp compare_text(nil, _text2), do: :added
  defp compare_text(_text1, nil), do: :removed
  defp compare_text(_text1, _text2), do: :changed

  defp compare_maps(map1, map2) when map1 == map2, do: :unchanged
  defp compare_maps(_map1, _map2), do: :changed
end
