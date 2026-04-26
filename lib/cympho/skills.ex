defmodule Cympho.Skills do
  @moduledoc """
  The Skills context manages company and project-level skills.
  """

  import Ecto.Query
  alias Cympho.{Repo, Skills.Skill, Skills.Plugin, Skills.AgentSkill}

  def list_skills(opts \\ []) do
    company_id = Keyword.get(opts, :company_id)
    project_id = Keyword.get(opts, :project_id)

    Skill
    |> maybe_filter_by_company(company_id)
    |> maybe_filter_by_project(project_id)
    |> order_by([s], asc: s.name)
    |> Repo.all()
  end

  def get_skill(id) do
    case Repo.get(Skill, id) do
      nil -> {:error, :not_found}
      skill -> {:ok, Repo.preload(skill, [:company, :project])}
    end
  end

  def get_skill_by_identifier(identifier, company_id) do
    query =
      from s in Skill,
      where: s.identifier == ^identifier and s.company_id == ^company_id

    case Repo.one(query) do
      nil -> {:error, :not_found}
      skill -> {:ok, skill}
    end
  end

  def create_skill(attrs \\ %{}) do
    %Skill{}
    |> Skill.changeset(attrs)
    |> Repo.insert()
  end

  def update_skill(%Skill{} = skill, attrs) do
    skill
    |> Skill.changeset(attrs)
    |> Repo.update()
  end

  def delete_skill(%Skill{} = skill) do
    Repo.delete(skill)
  end

  def toggle_skill(%Skill{} = skill) do
    update_skill(skill, %{enabled: not skill.enabled})
  end

  def update_skill_settings(%Skill{} = skill, settings) do
    update_skill(skill, %{settings: settings})
  end

  defp maybe_filter_by_company(query, nil), do: query
  defp maybe_filter_by_company(query, company_id) do
    from s in query, where: s.company_id == ^company_id
  end

  defp maybe_filter_by_project(query, nil), do: query
  defp maybe_filter_by_project(query, project_id) do
    from s in query, where: s.project_id == ^project_id
  end

  def change_skill(%Skill{} = skill, attrs \\ %{}) do
    Skill.changeset(skill, attrs)
  end

  @doc """
  Returns all enabled skills (plugins) assigned to an agent.
  """
  def list_skills_for_agent(agent_id) do
    query =
      from p in Plugin,
      join: agent_skill in AgentSkill,
      on: agent_skill.plugin_id == p.id,
      where: agent_skill.agent_id == ^agent_id and p.enabled == true,
      order_by: [asc: p.name]

    Repo.all(query)
  end

  @doc """
  Assigns a plugin (skill) to an agent with an optional version lock.
  """
  def assign_skill_to_agent(agent_id, plugin_id, opts \\ []) do
    attrs = %{
      agent_id: agent_id,
      plugin_id: plugin_id,
      locked_version: Keyword.get(opts, :locked_version)
    }

    %AgentSkill{}
    |> AgentSkill.changeset(attrs)
    |> Repo.insert(
      on_conflict: [set: [locked_version: attrs.locked_version]],
      conflict_target: [:agent_id, :plugin_id]
    )
  end

  @doc """
  Removes a skill (plugin) assignment from an agent.
  """
  def remove_skill_from_agent(agent_id, plugin_id) do
    query =
      from agent_skill in AgentSkill,
      where: agent_skill.agent_id == ^agent_id and agent_skill.plugin_id == ^plugin_id

    case Repo.one(query) do
      nil -> {:error, :not_found}
      agent_skill -> Repo.delete(agent_skill)
    end
  end

  @valid_statuses ~w(draft installed active disabled error)

  @doc """
  Updates the status of a plugin (skill).
  Valid statuses: draft, installed, active, disabled, error
  """
  def update_skill_status(%Plugin{} = plugin, status)
      when is_binary(status) and status in @valid_statuses do
    update_plugin(plugin, %{status: status})
  end

  @doc """
  Gets a plugin by ID.
  """
  def get_plugin(id) do
    case Repo.get(Plugin, id) do
      nil -> {:error, :not_found}
      plugin -> {:ok, plugin}
    end
  end

  @doc """
  Updates a plugin.
  """
  def update_plugin(%Plugin{} = plugin, attrs) do
    plugin
    |> Plugin.changeset(attrs)
    |> Repo.update()
  end
end

  @doc """
  Returns available skills for an agent as a list of maps for LLM prompts.

  Gracefully degrades on error - returns empty list and logs error.
  """
  def available_for_agent(agent_id) when is_binary(agent_id) do
    try do
      plugins = list_skills_for_agent(agent_id)

      Enum.map(plugins, fn plugin ->
        %{
          identifier: plugin.identifier,
          name: plugin.name,
          version: plugin.version || "0.0.0",
          capabilities: plugin.capabilities || [],
          description: plugin.description,
          entrypoint: plugin.entrypoint
        }
      end)
    rescue
      e ->
        :logger.error("[Skills] Failed to load skills for agent #{agent_id}: #{inspect(e)}")
        []
    end
  end
end
