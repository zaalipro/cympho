defmodule Cympho.AgentPrompt do
  @moduledoc """
  Builds the prompt contract used by autonomous runtime adapters.

  The prompt is intentionally explicit about the only side effects an agent can
  request. Agents propose state changes in a `cympho-actions` JSON block; the
  server validates and executes those actions.

  Structure (top to bottom):

    1. Issue block      — id, title, description, status, priority
    2. Agent block      — identity + role playbook + per-agent overrides
    3. Context block    — company/project/goal/lineage/parent
    4. History block    — recent comments, sub-issues, siblings, decisions
    5. Runtime block    — run id, workspace path
    6. Action contract  — per-role allowed/forbidden actions + JSON shape
    7. Skills block     — optional, when skills are passed in

  The role playbook (step 2) is the primary instruction surface; per-agent
  `agent.instructions` is layered as a supplement for company-specific quirks.
  """

  import Ecto.Query, warn: false

  alias Cympho.{Agents, Repo}
  alias Cympho.Agents.{Agent, RolePlaybook}
  alias Cympho.Comments.Comment
  alias Cympho.Decisions.Decision
  alias Cympho.Issues.Issue

  @recent_comments_limit 10
  @recent_decisions_limit 3
  @max_children 25
  @max_siblings 25

  @doc """
  Builds a prompt for an issue and optional agent.
  """
  def build(issue, agent_or_id \\ nil, opts \\ []) do
    skills = Keyword.get(opts, :skills, [])
    agent = resolve_agent(agent_or_id)
    history = load_history(issue)

    [
      issue_block(issue),
      agent_block(agent_or_id, agent),
      context_block(issue),
      history_block(history),
      runtime_block(Keyword.get(opts, :runtime_context)),
      action_contract_block(role_of(agent)),
      skills_block(skills)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
    |> String.trim()
  end

  defp issue_block(issue) do
    """
    Issue ID: #{field(issue, :id) || "unknown"}
    Identifier: #{field(issue, :identifier) || "unassigned"}
    Title: #{field(issue, :title) || "Untitled"}
    Status: #{field(issue, :status) || "unknown"}
    Priority: #{field(issue, :priority) || "medium"}
    Assigned role: #{field(issue, :assigned_role) || "inferred"}

    #{field(issue, :description) || "No description provided."}
    """
    |> String.trim()
  end

  defp agent_block(nil, nil), do: nil

  defp agent_block(agent_id, nil) do
    """
    Agent ID: #{agent_id || "unknown"}
    """
    |> String.trim()
  end

  defp agent_block(_agent_id, %Agent{} = agent) do
    parent = preloaded(agent, :parent)
    children = preloaded(agent, :children) || []

    playbook =
      RolePlaybook.for_role(agent.role, %{agent: agent, parent: parent, children: children})

    overrides =
      case String.trim(agent.instructions || "") do
        "" -> "(none)"
        text -> text
      end

    """
    Agent: #{agent.name || "unnamed"} (#{agent.role})
    Agent ID: #{agent.id}
    Agent title: #{agent.title || agent.name || "—"}

    #{playbook}

    ### Company-specific overrides for this agent
    #{overrides}
    """
    |> String.trim()
  end

  defp context_block(issue) do
    context =
      [
        context_line("Company", loaded_name(issue, :company, Cympho.Companies.Company)),
        context_line("Project", loaded_name(issue, :project, Cympho.Projects.Project)),
        context_line("Goal", loaded_name(issue, :goal, Cympho.Goals.Goal)),
        context_line("Parent issue", field(issue, :parent_id)),
        lineage_block(field(issue, :lineage))
      ]
      |> Enum.reject(&is_nil/1)

    if Enum.empty?(context) do
      nil
    else
      Enum.join(["Context" | context], "\n")
    end
  end

  defp lineage_block(nil), do: nil

  defp lineage_block(lineage) when is_map(lineage) do
    parts =
      [
        lineage_entry("Mission", lineage[:mission_id], Cympho.Goals.Goal),
        lineage_entry("Initiative", lineage[:initiative_id], Cympho.Goals.Goal),
        lineage_entry("Milestone", lineage[:milestone_id], Cympho.Goals.Goal)
      ]
      |> Enum.reject(&is_nil/1)

    if Enum.empty?(parts), do: nil, else: Enum.join(["Goal ancestry" | parts], "\n")
  end

  defp lineage_entry(_label, nil, _module), do: nil

  defp lineage_entry(label, id, module) do
    case Repo.get(module, id) do
      nil -> nil
      goal -> "#{label}: #{goal.title} (#{id})"
    end
  rescue
    _ -> nil
  end

  defp context_line(_label, nil), do: nil
  defp context_line(label, value), do: "#{label}: #{value}"

  ## ── history block ──────────────────────────────────────────────

  defp history_block(%{
         comments: comments,
         children: children,
         siblings: siblings,
         decisions: decisions
       })
       when comments == [] and children == [] and siblings == [] and decisions == [] do
    nil
  end

  defp history_block(history) do
    [
      "## Recent issue history",
      comments_section(history.comments),
      children_section(history.children),
      siblings_section(history.siblings),
      decisions_section(history.decisions)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  defp comments_section([]), do: nil

  defp comments_section(comments) do
    rows =
      Enum.map(comments, fn c ->
        author = comment_author_label(c)
        body = c.body |> String.split("\n") |> Enum.take(20) |> Enum.join("\n")
        "- [#{author}] #{body}"
      end)

    Enum.join(["### Recent comments (oldest → newest)" | rows], "\n")
  end

  defp comment_author_label(%Comment{author_type: type, author_id: id}) when is_binary(type) do
    case type do
      "agent" -> "agent #{short_id(id)}"
      "user" -> "user #{short_id(id)}"
      "system" -> "system"
      other -> other
    end
  end

  defp comment_author_label(_), do: "unknown"

  defp short_id(nil), do: "?"
  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 8)

  defp children_section([]), do: nil

  defp children_section(children) do
    rows = Enum.map(children, &issue_one_liner/1)

    Enum.join(
      [
        "### Sub-issues — these were spawned from this one. Track their state before approving."
        | rows
      ],
      "\n"
    )
  end

  defp siblings_section([]), do: nil

  defp siblings_section(siblings) do
    rows = Enum.map(siblings, &issue_one_liner/1)

    Enum.join(
      [
        "### Sibling issues (share a parent with the active issue) — parallel work to be aware of"
        | rows
      ],
      "\n"
    )
  end

  defp issue_one_liner(%Issue{} = i) do
    assignee_label =
      case preloaded(i, :assignee) do
        %Agent{name: name} -> name
        _ -> "unassigned"
      end

    "- #{i.identifier || short_id(i.id)} #{i.title || "(untitled)"} [#{i.status}] → #{assignee_label}"
  end

  defp decisions_section([]), do: nil

  defp decisions_section(decisions) do
    rows =
      Enum.map(decisions, fn d ->
        kind = Map.get(d, :decision_type) || "decision"
        label = Map.get(d, :decision_key) || Map.get(d, :reasoning) || "(no detail)"
        outcome = Map.get(d, :outcome)
        suffix = if outcome, do: " → #{outcome}", else: ""
        "- [#{kind}] #{truncate(label, 120)}#{suffix}"
      end)

    Enum.join(["### Recent company decisions" | rows], "\n")
  end

  defp truncate(text, max) when is_binary(text) do
    if String.length(text) <= max, do: text, else: String.slice(text, 0, max - 1) <> "…"
  end

  defp truncate(_, _), do: ""

  ## ── runtime block ──────────────────────────────────────────────

  defp runtime_block(%Cympho.RuntimeContext{} = context) do
    lines =
      [
        context_line("Run", context.run_id),
        context_line("Workspace", context.cwd),
        context_line("Workspace source", context.metadata["workspace_source"])
      ]
      |> Enum.reject(&is_nil/1)

    if Enum.empty?(lines), do: nil, else: Enum.join(["Runtime" | lines], "\n")
  end

  defp runtime_block(_context), do: nil

  ## ── action contract ───────────────────────────────────────────

  defp action_contract_block(role) do
    [
      action_contract_intro(),
      role_action_guidance(role),
      action_contract_example()
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  defp action_contract_intro do
    """
    ## Required response contract
    Return a concise summary followed by exactly one fenced `cympho-actions` block.
    The block must contain JSON with an `actions` array. The server will ignore
    any requested side effect that is not represented in this block.
    """
    |> String.trim()
  end

  defp role_action_guidance(:ceo) do
    """
    ### Allowed actions for your role (CEO)
    - `create_issue`, `approve_issue`, `request_changes`, `block_issue`, `comment`, `attach_work_product`, `set_pr_url`, `handoff`

    ### MUST NOT emit
    - `submit_review` — you have no supervisor; use `approve_issue` to close work. The server will reject `submit_review` from the CEO with `:no_supervisor_to_review`.
    """
    |> String.trim()
  end

  defp role_action_guidance(:cto) do
    """
    ### Allowed actions for your role (CTO)
    - `create_issue`, `submit_review`, `approve_issue`, `request_changes`, `block_issue`, `comment`, `attach_work_product`, `set_pr_url`, `handoff`

    All actions available. Use `submit_review` (routes to CEO) when you've personally produced a small piece of work; use `approve_issue`/`request_changes` to gate engineering submissions you receive.
    """
    |> String.trim()
  end

  defp role_action_guidance(:engineer) do
    """
    ### Allowed actions for your role (engineer)
    - `comment`, `attach_work_product`, `set_pr_url`, `submit_review`, `create_issue` (rare — only for genuine follow-up)

    ### MUST NOT emit
    - `approve_issue`, `request_changes`, `block_issue` — governance actions reserved for CEO/CTO. The server will reject with `:unauthorized_action`.
    - `handoff` — only when an issue is genuinely the wrong role for you; otherwise complete the work or `submit_review` with a blocked note.
    """
    |> String.trim()
  end

  defp role_action_guidance(:product_manager) do
    """
    ### Allowed actions for your role (product manager)
    - `create_issue`, `submit_review`, `comment`, `attach_work_product`

    ### MUST NOT emit
    - `approve_issue`, `request_changes`, `block_issue` — governance actions reserved for CEO/CTO.
    """
    |> String.trim()
  end

  defp role_action_guidance(:designer) do
    """
    ### Allowed actions for your role (designer)
    - `submit_review`, `comment`, `attach_work_product`

    ### MUST NOT emit
    - `approve_issue`, `request_changes`, `block_issue` — governance actions reserved for CEO/CTO.
    """
    |> String.trim()
  end

  defp role_action_guidance(_) do
    """
    ### Action types
    - `create_issue`, `submit_review`, `approve_issue`, `request_changes`, `block_issue`, `comment`, `attach_work_product`, `set_pr_url`, `handoff`

    Governance actions (`approve_issue`, `request_changes`, `block_issue`) are restricted to CEO and CTO roles; the server rejects them from other roles.
    """
    |> String.trim()
  end

  defp action_contract_example do
    """
    ### JSON shape and example
    Each action requires `type` plus the fields listed in the action playbook above.

    ```cympho-actions
    {
      "actions": [
        {
          "type": "create_issue",
          "title": "Implement billing usage summary",
          "description": "Add the missing usage cards and tests.",
          "role": "engineer",
          "priority": "high"
        },
        {
          "type": "submit_review",
          "role": "cto",
          "notes": "Implementation work has been delegated."
        }
      ]
    }
    ```
    """
    |> String.trim()
  end

  ## ── skills block ──────────────────────────────────────────────

  defp skills_block([]), do: nil

  defp skills_block(skills) when is_list(skills) do
    adapter = :claude_local

    skill_fragments =
      Enum.map(skills, fn skill ->
        Cympho.Skills.Adapter.skill_prompt_fragment(adapter, skill)
      end)

    """
    ## Available Skills

    The following skills are available for use in this session:
    #{Enum.join(skill_fragments, "\n")}
    """
    |> String.trim()
  end

  ## ── helpers ───────────────────────────────────────────────────

  defp resolve_agent(%Agent{} = agent), do: preload_agent_relations(agent)

  defp resolve_agent(agent_id) when is_binary(agent_id) do
    case Agents.get_agent(agent_id) do
      {:ok, agent} -> preload_agent_relations(agent)
      {:error, _} -> nil
    end
  rescue
    _ -> nil
  end

  defp resolve_agent(_), do: nil

  defp preload_agent_relations(%Agent{} = agent) do
    Repo.preload(agent, [:parent, :children])
  rescue
    _ -> agent
  end

  defp role_of(%Agent{role: role}), do: role
  defp role_of(_), do: nil

  defp preloaded(%{} = struct, key) do
    case Map.get(struct, key) do
      %Ecto.Association.NotLoaded{} -> nil
      value -> value
    end
  end

  defp preloaded(_, _), do: nil

  defp loaded_name(issue, assoc, module) do
    case field(issue, assoc) do
      %{__struct__: _struct, name: name} when is_binary(name) ->
        name

      %{__struct__: _struct, title: title} when is_binary(title) ->
        title

      %Ecto.Association.NotLoaded{} ->
        fetch_related_name(field(issue, :"#{assoc}_id"), module)

      nil ->
        fetch_related_name(field(issue, :"#{assoc}_id"), module)

      value ->
        value
    end
  end

  defp fetch_related_name(nil, _module), do: nil

  defp fetch_related_name(id, module) do
    case Repo.get(module, id) do
      nil -> nil
      %{name: name} when is_binary(name) -> name
      %{title: title} when is_binary(title) -> title
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp field(%{} = map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp field(_issue, _key), do: nil

  ## ── history loaders ───────────────────────────────────────────

  defp load_history(%{id: nil}), do: empty_history()

  defp load_history(%Issue{id: id} = issue) do
    %{
      comments: load_recent_comments(id),
      children: load_children(id),
      siblings: load_siblings(issue),
      decisions: load_recent_decisions(field(issue, :company_id), field(issue, :goal_id))
    }
  rescue
    _ -> empty_history()
  end

  defp load_history(%{id: id} = issue) when is_binary(id) do
    %{
      comments: load_recent_comments(id),
      children: load_children(id),
      siblings: load_siblings(issue),
      decisions: load_recent_decisions(field(issue, :company_id), field(issue, :goal_id))
    }
  rescue
    _ -> empty_history()
  end

  defp load_history(_), do: empty_history()

  defp empty_history, do: %{comments: [], children: [], siblings: [], decisions: []}

  defp load_recent_comments(issue_id) do
    Comment
    |> where([c], c.issue_id == ^issue_id)
    |> order_by([c], asc: c.inserted_at)
    |> limit(@recent_comments_limit)
    |> Repo.all()
  rescue
    _ -> []
  end

  defp load_children(parent_id) do
    Issue
    |> where([i], i.parent_id == ^parent_id)
    |> order_by([i], asc: i.inserted_at)
    |> limit(@max_children)
    |> Repo.all()
    |> Repo.preload(:assignee)
  rescue
    _ -> []
  end

  defp load_siblings(%{parent_id: nil}), do: []

  defp load_siblings(%{parent_id: parent_id, id: id}) when is_binary(parent_id) do
    Issue
    |> where([i], i.parent_id == ^parent_id and i.id != ^id)
    |> order_by([i], asc: i.inserted_at)
    |> limit(@max_siblings)
    |> Repo.all()
    |> Repo.preload(:assignee)
  rescue
    _ -> []
  end

  defp load_siblings(_), do: []

  defp load_recent_decisions(nil, _goal_id), do: []

  defp load_recent_decisions(company_id, goal_id) do
    base = where(Decision, [d], d.company_id == ^company_id)

    base =
      cond do
        goal_id && schema_has_field?(Decision, :goal_id) ->
          where(base, [d], d.goal_id == ^goal_id or is_nil(d.goal_id))

        true ->
          base
      end

    base
    |> order_by([d], desc: d.inserted_at)
    |> limit(@recent_decisions_limit)
    |> Repo.all()
  rescue
    _ -> []
  end

  defp schema_has_field?(module, field) do
    field in module.__schema__(:fields)
  rescue
    _ -> false
  end
end
