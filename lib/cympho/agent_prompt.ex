defmodule Cympho.AgentPrompt do
  @moduledoc """
  Builds the prompt contract used by autonomous runtime adapters.

  The prompt is intentionally explicit about the only side effects an agent can
  request. Agents propose state changes in a `cympho-actions` JSON block; the
  server validates and executes those actions.
  """

  alias Cympho.{Agents, Repo}

  @doc """
  Builds a prompt for an issue and optional agent.
  """
  def build(issue, agent_or_id \\ nil, opts \\ []) do
    skills = Keyword.get(opts, :skills, [])
    agent = resolve_agent(agent_or_id)

    [
      issue_block(issue),
      agent_block(agent_or_id, agent),
      context_block(issue),
      runtime_block(Keyword.get(opts, :runtime_context)),
      action_contract_block(),
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

  defp agent_block(_agent_id, agent) do
    """
    Agent ID: #{agent.id}
    Agent role: #{agent.role}
    Agent title: #{agent.title || agent.name}

    #{agent.instructions || "Use company context, complete the assigned work, and delegate follow-up work through cympho-actions."}
    """
    |> String.trim()
  end

  defp context_block(issue) do
    context =
      [
        context_line("Company", loaded_name(issue, :company, Cympho.Companies.Company)),
        context_line("Project", loaded_name(issue, :project, Cympho.Projects.Project)),
        context_line("Goal", loaded_name(issue, :goal, Cympho.Goals.Goal)),
        context_line("Parent issue", field(issue, :parent_id))
      ]
      |> Enum.reject(&is_nil/1)

    if Enum.empty?(context) do
      nil
    else
      Enum.join(["Context" | context], "\n")
    end
  end

  defp context_line(_label, nil), do: nil
  defp context_line(label, value), do: "#{label}: #{value}"

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

  defp action_contract_block do
    """
    Required response contract:
    Return a concise summary followed by exactly one fenced `cympho-actions` block.
    The block must contain JSON with an `actions` array. The server will ignore
    any requested side effect that is not represented in this block.

    Supported actions:
    - create_issue: title, role, description, priority
    - submit_review: role, notes
    - approve_issue: notes
    - request_changes: role, reason
    - block_issue: reason
    - comment: body
    - attach_work_product: title, kind, description, url, payload, metadata
    - set_pr_url: url, notes
    - handoff: role, reason

    Example:
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

  defp resolve_agent(%Cympho.Agents.Agent{} = agent), do: agent

  defp resolve_agent(agent_id) when is_binary(agent_id) do
    case Agents.get_agent(agent_id) do
      {:ok, agent} -> agent
      {:error, _} -> nil
    end
  rescue
    _ -> nil
  end

  defp resolve_agent(_), do: nil

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
end
