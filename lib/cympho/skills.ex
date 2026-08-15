defmodule Cympho.Skills do
  @moduledoc """
  The Skills context manages company and project-level skills.
  """

  import Ecto.Query
  require Logger
  alias Cympho.Repo
  alias Cympho.Skills.{AgentSkill, Manifest, Plugin, Skill}

  def list_skills(opts \\ []) do
    company_id = Keyword.get(opts, :company_id)
    project_id = Keyword.get(opts, :project_id)

    Skill
    |> maybe_filter_by_company(company_id)
    |> maybe_filter_by_project(project_id)
    |> order_by([s], asc: s.name)
    |> preload([:company, :project])
    |> Repo.all()
  end

  @doc """
  Keyset (infinite-scroll) page of skills, ordered by name.

  Accepts the same `:company_id`/`:project_id` filters as `list_skills/1` plus
  `:after` (a cursor) and `:limit`, returns a `Cympho.Pagination.Page` with
  `:company` and `:project` preloaded. Keys on `(name, id)` to match the display
  order of `list_skills/1`.
  """
  def list_skills_page(opts \\ []) do
    Skill
    |> maybe_filter_by_company(Keyword.get(opts, :company_id))
    |> maybe_filter_by_project(Keyword.get(opts, :project_id))
    |> Cympho.Pagination.page(
      limit: Keyword.get(opts, :limit, 50),
      after: Keyword.get(opts, :after),
      cursor_fields: [{:name, :asc}, {:id, :asc}]
    )
    |> then(fn page -> %{page | entries: Repo.preload(page.entries, [:company, :project])} end)
  end

  def get_skill(id) do
    case Repo.get(Skill, id) do
      nil -> {:error, :not_found}
      skill -> {:ok, Repo.preload(skill, [:company, :project])}
    end
  end

  def get_company_skill(company_id, id) do
    query = from s in Skill, where: s.id == ^id and s.company_id == ^company_id

    case Repo.one(query) do
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

  @doc """
  Summarizes first-party skill readiness for operators.

  Skills are useful only when enabled entries have valid manifests, explicit
  capabilities, and the development hot-reloader is alive enough to refresh
  manifest changes without restarting agent runtime loops.
  """
  def health_summary(company_id \\ nil, opts \\ []) do
    hot_reloader_running? =
      Keyword.get(opts, :hot_reloader_running?, hot_reloader_running?())

    skills =
      company_id
      |> skill_health_query()
      |> Repo.all()

    metrics = skill_health_metrics(skills, hot_reloader_running?)
    recommendations = skill_health_recommendations(metrics)
    level = skill_health_level(metrics)

    %{
      level: level,
      label: skill_health_label(level),
      summary: skill_health_summary(metrics),
      metrics: metrics,
      recommendations: recommendations,
      next_action: skill_health_next_action(level, recommendations)
    }
  end

  defp skill_health_query(nil), do: from(skill in Skill)

  defp skill_health_query(company_id) do
    from(skill in Skill, where: skill.company_id == ^company_id)
  end

  defp skill_health_metrics(skills, hot_reloader_running?) do
    enabled_skills = Enum.filter(skills, & &1.enabled)

    %{
      total_skills: length(skills),
      enabled_skills: length(enabled_skills),
      disabled_skills: Enum.count(skills, &(!&1.enabled)),
      invalid_manifest_skills: Enum.count(skills, &(not valid_skill_manifest?(&1))),
      capabilityless_enabled_skills: Enum.count(enabled_skills, &capabilityless_skill?/1),
      hot_reloader_running?: hot_reloader_running?
    }
  end

  defp valid_skill_manifest?(%Skill{manifest: manifest}) do
    match?({:ok, _}, Manifest.validate(manifest))
  end

  defp capabilityless_skill?(%Skill{} = skill) do
    valid_skill_manifest?(skill) and manifest_capabilities(skill) == []
  end

  defp manifest_capabilities(%Skill{manifest: manifest}) when is_map(manifest) do
    case Map.get(manifest, "capabilities") || Map.get(manifest, :capabilities) do
      capabilities when is_list(capabilities) -> capabilities
      _ -> []
    end
  end

  defp manifest_capabilities(_skill), do: []

  defp hot_reloader_running?, do: Process.whereis(Cympho.Skills.HotReloader) != nil

  defp skill_health_recommendations(metrics) do
    []
    |> maybe_recommend(
      metrics.invalid_manifest_skills > 0,
      :repair_manifests,
      :critical,
      "Repair manifests",
      "#{metrics.invalid_manifest_skills} skill #{plural(metrics.invalid_manifest_skills, "manifest")} #{verb(metrics.invalid_manifest_skills, "is", "are")} missing required runtime fields."
    )
    |> maybe_recommend(
      metrics.capabilityless_enabled_skills > 0,
      :declare_capabilities,
      :warning,
      "Declare capabilities",
      "#{metrics.capabilityless_enabled_skills} enabled #{plural(metrics.capabilityless_enabled_skills, "skill")} #{verb(metrics.capabilityless_enabled_skills, "has", "have")} valid manifests but no capability list."
    )
    |> maybe_recommend(
      not metrics.hot_reloader_running? and metrics.total_skills > 0,
      :start_hot_reloader,
      :warning,
      "Check hot reload",
      "Skill manifest changes will not refresh automatically while the hot-reloader process is unavailable."
    )
    |> maybe_recommend(
      metrics.disabled_skills > 0,
      :audit_disabled_skills,
      :info,
      "Audit disabled skills",
      "#{metrics.disabled_skills} #{plural(metrics.disabled_skills, "skill")} #{verb(metrics.disabled_skills, "is", "are")} disabled and unavailable to agents."
    )
  end

  defp maybe_recommend(recommendations, false, _key, _severity, _label, _detail),
    do: recommendations

  defp maybe_recommend(recommendations, true, key, severity, label, detail) do
    recommendations ++ [%{key: key, severity: severity, label: label, detail: detail}]
  end

  defp skill_health_next_action(:empty, _recommendations) do
    %{
      key: :create_first_skill,
      tone: :neutral,
      label: "Create first skill",
      detail:
        "Start with one narrow capability, define its manifest, and assign it only where the agent can produce evidence with it.",
      cta: "New skill"
    }
  end

  defp skill_health_next_action(:healthy, []) do
    %{
      key: :review_prompt_fit,
      tone: :ok,
      label: "Review prompt fit",
      detail:
        "Enabled skills have valid manifests and explicit capabilities. Confirm agent prompts name when to use each skill before adding more.",
      cta: "Open skills"
    }
  end

  defp skill_health_next_action(_level, [recommendation | _]) do
    %{
      key: recommendation.key,
      tone: recommendation.severity,
      label: recommendation.label,
      detail: skill_next_action_detail(recommendation),
      cta: skill_next_action_cta(recommendation.key)
    }
  end

  defp skill_health_next_action(_level, _recommendations) do
    %{
      key: :review_skills,
      tone: :neutral,
      label: "Review skills",
      detail: "Inspect skill manifests before expanding agent capability access.",
      cta: "Open skills"
    }
  end

  defp skill_next_action_detail(%{key: :repair_manifests, detail: detail}) do
    "#{detail} A valid manifest needs name, version, author, entrypoint, and runtime-safe capabilities."
  end

  defp skill_next_action_detail(%{key: :declare_capabilities, detail: detail}) do
    "#{detail} Capabilities tell agents when a skill is appropriate and make prompt routing auditable."
  end

  defp skill_next_action_detail(%{key: :start_hot_reloader, detail: detail}) do
    "#{detail} Restart the runtime or inspect the operations checklist before editing manifests."
  end

  defp skill_next_action_detail(%{detail: detail}), do: detail

  defp skill_next_action_cta(:repair_manifests), do: "Review manifests"
  defp skill_next_action_cta(:declare_capabilities), do: "Open skills"
  defp skill_next_action_cta(:start_hot_reloader), do: "Open runtime checklist"
  defp skill_next_action_cta(:audit_disabled_skills), do: "Audit disabled"
  defp skill_next_action_cta(_key), do: "Open skills"

  defp skill_health_level(%{total_skills: 0}), do: :empty

  defp skill_health_level(%{invalid_manifest_skills: invalid}) when invalid > 0, do: :critical

  defp skill_health_level(%{
         capabilityless_enabled_skills: capabilityless,
         disabled_skills: disabled,
         hot_reloader_running?: hot_reloader_running?
       })
       when capabilityless > 0 or disabled > 0 or not hot_reloader_running?,
       do: :warning

  defp skill_health_level(_metrics), do: :healthy

  defp skill_health_label(:critical), do: "Needs attention"
  defp skill_health_label(:warning), do: "Watch"
  defp skill_health_label(:healthy), do: "Healthy"
  defp skill_health_label(:empty), do: "Not configured"

  defp skill_health_summary(%{total_skills: 0}) do
    "No skills are configured for this company yet."
  end

  defp skill_health_summary(%{invalid_manifest_skills: invalid}) when invalid > 0 do
    "#{invalid} skill #{plural(invalid, "manifest")} #{verb(invalid, "needs", "need")} repair before agents can rely on them."
  end

  defp skill_health_summary(%{
         capabilityless_enabled_skills: capabilityless,
         disabled_skills: disabled,
         hot_reloader_running?: false
       }) do
    "#{capabilityless} capability #{plural(capabilityless, "gap")}, #{disabled} disabled #{plural(disabled, "skill")}, and hot reload needs review."
  end

  defp skill_health_summary(%{
         capabilityless_enabled_skills: capabilityless,
         disabled_skills: disabled
       })
       when capabilityless > 0 or disabled > 0 do
    "#{capabilityless} capability #{plural(capabilityless, "gap")} and #{disabled} disabled #{plural(disabled, "skill")} need review."
  end

  defp skill_health_summary(%{enabled_skills: enabled}) do
    "#{enabled} enabled #{plural(enabled, "skill")} #{verb(enabled, "has", "have")} valid manifests and explicit capabilities."
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
  Returns all prompt-usable skills (plugins) assigned to an agent.

  Disabled, errored, or manifest-broken plugin assignments remain visible to
  operators via `list_skill_assignments_for_agent/1`, but they are excluded from
  runtime prompt injection.
  """
  def list_skills_for_agent(agent_id) do
    query =
      from p in Plugin,
        join: agent_skill in AgentSkill,
        on: agent_skill.plugin_id == p.id,
        where: agent_skill.agent_id == ^agent_id and p.enabled == true,
        order_by: [asc: p.name]

    query
    |> Repo.all()
    |> Enum.filter(&prompt_usable_plugin?/1)
  end

  @doc """
  Returns all plugin skill assignments for an agent, including inactive or
  errored plugins that will not be injected into prompts.
  """
  def list_skill_assignments_for_agent(agent_id) do
    Repo.all(
      from agent_skill in AgentSkill,
        join: plugin in assoc(agent_skill, :plugin),
        where: agent_skill.agent_id == ^agent_id,
        order_by: [asc: plugin.name],
        preload: [plugin: plugin]
    )
  end

  @doc """
  Summarizes an agent's skill loadout for prompt readiness.

  This distinguishes assignment state from prompt injection state so operators
  can see when a checked skill is disabled, errored, or missing capability scope.
  """
  def agent_skill_summary(agent_id, company_id \\ nil) do
    available_plugins = list_plugins(company_id: company_id)

    assigned_plugins =
      agent_id
      |> list_skill_assignments_for_agent()
      |> Enum.map(& &1.plugin)
      |> Enum.filter(&plugin_in_company?(&1, company_id))

    metrics = agent_skill_metrics(available_plugins, assigned_plugins)
    recommendations = agent_skill_recommendations(metrics)
    level = agent_skill_level(metrics)

    %{
      level: level,
      label: agent_skill_label(level),
      summary: agent_skill_summary_text(metrics),
      metrics: metrics,
      recommendations: recommendations,
      next_action: agent_skill_next_action(level, recommendations)
    }
  end

  defp plugin_in_company?(_plugin, nil), do: true
  defp plugin_in_company?(%Plugin{company_id: company_id}, company_id), do: true
  defp plugin_in_company?(_plugin, _company_id), do: false

  defp agent_skill_metrics(available_plugins, assigned_plugins) do
    assigned_ids = MapSet.new(assigned_plugins, & &1.id)
    prompt_ready = Enum.count(assigned_plugins, &prompt_usable_plugin?/1)

    %{
      available_plugins: length(available_plugins),
      assigned_plugins: length(assigned_plugins),
      prompt_ready_plugins: prompt_ready,
      unassigned_plugins: Enum.count(available_plugins, &(!MapSet.member?(assigned_ids, &1.id))),
      inactive_assignments: Enum.count(assigned_plugins, &inactive_plugin?/1),
      manifest_error_assignments: Enum.count(assigned_plugins, &plugin_manifest_error?/1),
      capabilityless_assignments:
        Enum.count(assigned_plugins, &(prompt_usable_plugin?(&1) and capabilityless_plugin?(&1)))
    }
  end

  defp agent_skill_recommendations(metrics) do
    []
    |> maybe_recommend(
      metrics.available_plugins == 0,
      :install_first_skill,
      :neutral,
      "Install first skill",
      "No plugin-backed skills are available for this company."
    )
    |> maybe_recommend(
      metrics.available_plugins > 0 and metrics.assigned_plugins == 0,
      :assign_first_skill,
      :warning,
      "Assign first skill",
      "This agent has no skill assignments, so its runtime prompt receives no reusable capabilities."
    )
    |> maybe_recommend(
      metrics.manifest_error_assignments > 0,
      :repair_assigned_skills,
      :critical,
      "Repair assigned skills",
      "#{metrics.manifest_error_assignments} assigned #{plural(metrics.manifest_error_assignments, "skill")} #{verb(metrics.manifest_error_assignments, "is", "are")} errored or #{verb(metrics.manifest_error_assignments, "has", "have")} manifest validation errors."
    )
    |> maybe_recommend(
      metrics.inactive_assignments > 0,
      :review_inactive_assignments,
      :warning,
      "Review inactive assignments",
      "#{metrics.inactive_assignments} assigned #{plural(metrics.inactive_assignments, "skill")} #{verb(metrics.inactive_assignments, "is", "are")} disabled and will not reach the prompt."
    )
    |> maybe_recommend(
      metrics.capabilityless_assignments > 0,
      :scope_assigned_capabilities,
      :warning,
      "Scope assigned capabilities",
      "#{metrics.capabilityless_assignments} prompt-usable assigned #{plural(metrics.capabilityless_assignments, "skill")} #{verb(metrics.capabilityless_assignments, "declares", "declare")} no capabilities."
    )
  end

  defp agent_skill_next_action(:empty, _recommendations) do
    %{
      key: :install_first_skill,
      tone: :neutral,
      label: "Install first skill",
      detail:
        "Add one plugin-backed skill before expecting this agent to use reusable runtime capabilities.",
      cta: "Open marketplace"
    }
  end

  defp agent_skill_next_action(:healthy, []) do
    %{
      key: :review_prompt_skills,
      tone: :ok,
      label: "Review prompt skills",
      detail:
        "Assigned skills are prompt-ready. Keep the list narrow so the agent can explain when each skill was used.",
      cta: "Review skills"
    }
  end

  defp agent_skill_next_action(_level, [recommendation | _]) do
    %{
      key: recommendation.key,
      tone: recommendation.severity,
      label: recommendation.label,
      detail: agent_skill_next_action_detail(recommendation),
      cta: agent_skill_next_action_cta(recommendation.key)
    }
  end

  defp agent_skill_next_action(_level, _recommendations) do
    %{
      key: :review_skill_loadout,
      tone: :neutral,
      label: "Review skill loadout",
      detail: "Inspect assigned skills before increasing this agent's runtime autonomy.",
      cta: "Review skills"
    }
  end

  defp agent_skill_next_action_detail(%{key: :assign_first_skill, detail: detail}) do
    "#{detail} Assign only skills this role can verify and report in its evidence packet."
  end

  defp agent_skill_next_action_detail(%{key: :repair_assigned_skills, detail: detail}) do
    "#{detail} Repair or remove them so the prompt does not advertise broken capabilities."
  end

  defp agent_skill_next_action_detail(%{key: :review_inactive_assignments, detail: detail}) do
    "#{detail} Re-enable the plugin or remove the assignment to avoid false confidence."
  end

  defp agent_skill_next_action_detail(%{key: :scope_assigned_capabilities, detail: detail}) do
    "#{detail} Capabilities keep agent tool choice auditable."
  end

  defp agent_skill_next_action_detail(%{detail: detail}), do: detail

  defp agent_skill_next_action_cta(:install_first_skill), do: "Open marketplace"
  defp agent_skill_next_action_cta(:assign_first_skill), do: "Assign skills"
  defp agent_skill_next_action_cta(:repair_assigned_skills), do: "Open plugins"
  defp agent_skill_next_action_cta(:review_inactive_assignments), do: "Review assignments"
  defp agent_skill_next_action_cta(:scope_assigned_capabilities), do: "Open plugins"
  defp agent_skill_next_action_cta(_key), do: "Review skills"

  defp agent_skill_level(%{available_plugins: 0}), do: :empty
  defp agent_skill_level(%{manifest_error_assignments: errors}) when errors > 0, do: :critical

  defp agent_skill_level(%{assigned_plugins: assigned, prompt_ready_plugins: ready})
       when assigned > 0 and ready == 0,
       do: :critical

  defp agent_skill_level(%{assigned_plugins: 0}), do: :warning

  defp agent_skill_level(%{
         inactive_assignments: inactive,
         capabilityless_assignments: capabilityless
       })
       when inactive > 0 or capabilityless > 0,
       do: :warning

  defp agent_skill_level(_metrics), do: :healthy

  defp agent_skill_label(:critical), do: "Needs repair"
  defp agent_skill_label(:warning), do: "Watch"
  defp agent_skill_label(:healthy), do: "Prompt-ready"
  defp agent_skill_label(:empty), do: "No library"

  defp agent_skill_summary_text(%{available_plugins: 0}) do
    "No plugin-backed skills are available for this company."
  end

  defp agent_skill_summary_text(%{assigned_plugins: 0, available_plugins: available}) do
    "#{available} #{plural(available, "skill")} #{verb(available, "is", "are")} available, but none are assigned to this agent."
  end

  defp agent_skill_summary_text(%{
         prompt_ready_plugins: ready,
         assigned_plugins: assigned,
         manifest_error_assignments: errors,
         inactive_assignments: inactive,
         capabilityless_assignments: capabilityless
       })
       when errors > 0 or inactive > 0 or capabilityless > 0 do
    "#{ready}/#{assigned} assigned #{plural(assigned, "skill")} prompt-ready; #{errors} repair, #{inactive} inactive, #{capabilityless} capability #{plural(capabilityless, "gap")}."
  end

  defp agent_skill_summary_text(%{prompt_ready_plugins: ready, assigned_plugins: assigned}) do
    "#{ready}/#{assigned} assigned #{plural(assigned, "skill")} prompt-ready for this agent."
  end

  defp prompt_usable_plugin?(%Plugin{} = plugin) do
    plugin.enabled and plugin.status in ["installed", "active"] and
      not plugin_manifest_error?(plugin)
  end

  defp inactive_plugin?(%Plugin{} = plugin) do
    not plugin.enabled or plugin.status == "disabled"
  end

  defp plugin_manifest_error?(%Plugin{status: "error"}), do: true

  defp plugin_manifest_error?(%Plugin{manifest_errors: errors}) when is_map(errors) do
    map_size(errors) > 0
  end

  defp plugin_manifest_error?(_plugin), do: false

  defp capabilityless_plugin?(%Plugin{capabilities: capabilities}) do
    not is_list(capabilities) or capabilities == []
  end

  @doc """
  Assigns a plugin (skill) to an agent with an optional version lock.
  """
  def assign_skill_to_agent(agent_id, plugin_id, opts \\ []) do
    # `plugin_id` reaches here straight from a LiveView event payload, which is
    # client-controlled, and nothing upstream constrains it to the caller's
    # company. Without this check a crafted event attaches any tenant's plugin
    # to your own agent.
    with {:ok, agent} <- fetch_agent(agent_id),
         {:ok, plugin} <- fetch_plugin(plugin_id),
         :ok <- same_company(agent, plugin) do
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
  end

  defp fetch_agent(agent_id) do
    case Repo.get(Cympho.Agents.Agent, agent_id) do
      nil -> {:error, :not_found}
      agent -> {:ok, agent}
    end
  end

  defp fetch_plugin(plugin_id) do
    case Repo.get(Plugin, plugin_id) do
      nil -> {:error, :not_found}
      plugin -> {:ok, plugin}
    end
  end

  defp same_company(%{company_id: same}, %Plugin{company_id: same}) when is_binary(same), do: :ok
  defp same_company(_agent, _plugin), do: {:error, :company_mismatch}

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

  @doc """
  Lists plugins, optionally filtered by company, project, or status.
  """
  def list_plugins(opts \\ []) do
    company_id = Keyword.get(opts, :company_id)
    project_id = Keyword.get(opts, :project_id)
    status = Keyword.get(opts, :status)

    Plugin
    |> maybe_filter_by_company(company_id)
    |> maybe_filter_by_project(project_id)
    |> maybe_filter_by_status(status)
    |> order_by([p], asc: p.name)
    |> preload([:company, :project])
    |> Repo.all()
  end

  @doc """
  Keyset (infinite-scroll) page of plugins, ordered by name.

  Accepts the same filter options as `list_plugins/1` plus `:after` (a cursor)
  and `:limit`, and returns a `Cympho.Pagination.Page` with `:company` and
  `:project` preloaded. Keys on `(name, id)`.
  """
  def list_plugins_page(opts \\ []) do
    Plugin
    |> maybe_filter_by_company(Keyword.get(opts, :company_id))
    |> maybe_filter_by_project(Keyword.get(opts, :project_id))
    |> maybe_filter_by_status(Keyword.get(opts, :status))
    |> Cympho.Pagination.page(
      limit: Keyword.get(opts, :limit, 50),
      after: Keyword.get(opts, :after),
      cursor_fields: [{:name, :asc}, {:id, :asc}]
    )
    |> then(fn page -> %{page | entries: Repo.preload(page.entries, [:company, :project])} end)
  end

  @doc """
  Gets a plugin by id scoped to a company.
  """
  def get_company_plugin(company_id, id) do
    query = from p in Plugin, where: p.id == ^id and p.company_id == ^company_id

    case Repo.one(query) do
      nil -> {:error, :not_found}
      plugin -> {:ok, Repo.preload(plugin, [:company, :project])}
    end
  end

  @doc """
  Gets a plugin by its identifier within a company.
  """
  def get_plugin_by_identifier(identifier, company_id) do
    query =
      from p in Plugin,
        where: p.identifier == ^identifier and p.company_id == ^company_id

    case Repo.one(query) do
      nil -> {:error, :not_found}
      plugin -> {:ok, plugin}
    end
  end

  @doc """
  Creates a plugin.
  """
  def create_plugin(attrs \\ %{}) do
    %Plugin{}
    |> Plugin.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Deletes a plugin.
  """
  def delete_plugin(%Plugin{} = plugin) do
    Repo.delete(plugin)
  end

  @doc """
  Toggles a plugin's enabled flag and syncs the status ("active" when enabled,
  "disabled" otherwise).
  """
  def toggle_plugin(%Plugin{} = plugin) do
    new_enabled = not plugin.enabled
    new_status = if new_enabled, do: "active", else: "disabled"

    update_plugin(plugin, %{enabled: new_enabled, status: new_status})
  end

  @doc """
  Merges new settings into a plugin's existing settings map.
  """
  def update_plugin_settings(%Plugin{} = plugin, settings) do
    current_settings = plugin.settings || %{}
    updated_settings = Map.merge(current_settings, settings)

    update_plugin(plugin, %{settings: updated_settings})
  end

  @doc """
  Returns a changeset for a plugin without persisting.
  """
  def change_plugin(%Plugin{} = plugin, attrs \\ %{}) do
    Plugin.changeset(plugin, attrs)
  end

  defp maybe_filter_by_status(query, nil), do: query

  defp maybe_filter_by_status(query, status) do
    from p in query, where: p.status == ^status
  end

  @doc """
  Returns available skills for an agent as a list of maps for LLM prompts.

  Gracefully degrades on error - returns empty list and logs error.
  """
  def available_for_agent(agent_id) when is_binary(agent_id) do
    try do
      plugins = list_skills_for_agent(agent_id)

      Enum.map(plugins, fn plugin ->
        manifest = plugin.manifest || %{}

        %{
          identifier: plugin.identifier,
          name: plugin.name,
          version: plugin.version || "0.0.0",
          capabilities: plugin.capabilities || [],
          description: plugin.description,
          entrypoint: Map.get(manifest, "entrypoint")
        }
      end)
    rescue
      e ->
        Logger.debug("[Skills] Failed to load skills for agent #{agent_id}: #{inspect(e)}")
        []
    end
  end

  # Owner-facing summaries should read as sentences: "1 skill is available",
  # not "1 skill(s) are available".
  defp plural(1, word), do: word
  defp plural(_n, word), do: word <> "s"

  defp verb(1, singular, _plural), do: singular
  defp verb(_n, _singular, plural), do: plural
end
