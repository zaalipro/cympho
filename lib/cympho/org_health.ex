defmodule Cympho.OrgHealth do
  @moduledoc """
  Read-only diagnostics for the agent reporting structure.

  The org chart shows the tree; this module explains whether that tree is
  operationally usable by checking leadership coverage, detached reports,
  manager span, role coverage, and inactive/degraded agents.
  """

  import Ecto.Query, warn: false

  alias Cympho.Agents
  alias Cympho.Agents.Agent
  alias Cympho.Issues.Issue
  alias Cympho.Orchestrator.Dispatcher.Router
  alias Cympho.Repo

  @max_direct_reports 6
  @core_roles [:ceo, :cto]
  @demand_statuses [:todo, :in_progress, :in_review, :blocked]
  @delivery_roles Agent.delivery_roles()

  def snapshot(nil), do: empty_snapshot("No company selected.")

  def snapshot(company_id) when is_binary(company_id) do
    build_snapshot(Agents.list_agents_by_company(company_id), issue_role_demand(company_id))
  end

  def snapshot(agents) when is_list(agents), do: build_snapshot(agents)

  defp build_snapshot(agents, issue_role_demand \\ %{}) do
    active_agents = Enum.reject(agents, &terminated?/1)
    counts_by_role = Enum.frequencies_by(active_agents, & &1.role)
    active_ids = active_agents |> Enum.map(& &1.id) |> MapSet.new()
    direct_report_counts = direct_report_counts(active_agents, active_ids)
    missing_roles = missing_roles(counts_by_role)
    role_demand_gaps = role_demand_gaps(issue_role_demand, counts_by_role, active_agents)
    detached = detached_agents(active_agents, active_ids)
    overloaded = overloaded_managers(active_agents, direct_report_counts)
    inactive = Enum.filter(active_agents, &inactive?/1)
    degraded = Enum.filter(active_agents, &degraded?/1)

    level =
      cond do
        missing_roles != [] or detached != [] ->
          :critical

        role_demand_gaps != [] or overloaded != [] or inactive != [] or degraded != [] ->
          :warning

        true ->
          :healthy
      end

    metrics = %{
      total_agents: length(active_agents),
      root_leaders: Enum.count(active_agents, &is_nil(&1.parent_id)),
      missing_roles: length(missing_roles),
      role_demand_gaps: length(role_demand_gaps),
      unstaffed_role_issues: unstaffed_role_issue_count(role_demand_gaps),
      detached_agents: length(detached),
      overloaded_managers: length(overloaded),
      inactive_agents: length(inactive),
      degraded_agents: length(degraded),
      max_direct_reports: max_direct_reports(direct_report_counts)
    }

    %{
      level: level,
      label: label(level),
      summary: summary(level, metrics, missing_roles),
      metrics: metrics,
      by_role: counts_by_role,
      missing_roles: missing_roles,
      role_demand_gaps: role_demand_gaps,
      detached_agents: agent_refs(detached),
      overloaded_managers:
        overloaded
        |> Enum.map(fn agent ->
          Map.put(agent_ref(agent), :direct_reports, Map.get(direct_report_counts, agent.id, 0))
        end),
      inactive_agents: agent_refs(inactive),
      degraded_agents: agent_refs(degraded),
      recommendations:
        recommendations(
          level,
          missing_roles,
          role_demand_gaps,
          detached,
          overloaded,
          inactive,
          degraded
        )
    }
  end

  defp empty_snapshot(summary) do
    %{
      level: :unknown,
      label: "Unknown",
      summary: summary,
      metrics: %{
        total_agents: 0,
        root_leaders: 0,
        missing_roles: 0,
        role_demand_gaps: 0,
        unstaffed_role_issues: 0,
        detached_agents: 0,
        overloaded_managers: 0,
        inactive_agents: 0,
        degraded_agents: 0,
        max_direct_reports: 0
      },
      by_role: %{},
      missing_roles: [],
      role_demand_gaps: [],
      detached_agents: [],
      overloaded_managers: [],
      inactive_agents: [],
      degraded_agents: [],
      recommendations: []
    }
  end

  defp terminated?(%Agent{status: :terminated}), do: true
  defp terminated?(%Agent{governance_status: "terminated"}), do: true
  defp terminated?(_agent), do: false

  defp inactive?(%Agent{status: status}) when status in [:error, :offline, :paused], do: true

  defp inactive?(%Agent{governance_status: status}) when status in ["paused", "suspended"],
    do: true

  defp inactive?(_agent), do: false

  defp degraded?(%Agent{health_status: status}) when status in [:degraded, :unavailable], do: true
  defp degraded?(_agent), do: false

  defp direct_report_counts(agents, active_ids) do
    agents
    |> Enum.filter(&(&1.parent_id in active_ids))
    |> Enum.frequencies_by(& &1.parent_id)
  end

  defp missing_roles(counts_by_role) do
    delivery_count =
      Agent.delivery_roles()
      |> Enum.map(&Map.get(counts_by_role, &1, 0))
      |> Enum.sum()

    @core_roles
    |> Enum.filter(&(Map.get(counts_by_role, &1, 0) == 0))
    |> then(fn roles ->
      if delivery_count == 0, do: roles ++ [:delivery], else: roles
    end)
  end

  defp detached_agents(agents, active_ids) do
    Enum.filter(agents, fn agent ->
      is_binary(agent.parent_id) and not MapSet.member?(active_ids, agent.parent_id)
    end)
  end

  defp overloaded_managers(agents, direct_report_counts) do
    Enum.filter(agents, fn agent ->
      Map.get(direct_report_counts, agent.id, 0) > @max_direct_reports
    end)
  end

  defp max_direct_reports(direct_report_counts) when map_size(direct_report_counts) == 0, do: 0

  defp max_direct_reports(direct_report_counts) do
    direct_report_counts
    |> Map.values()
    |> Enum.max()
  end

  defp agent_refs(agents), do: Enum.map(agents, &agent_ref/1)

  defp agent_ref(%Agent{} = agent) do
    %{
      id: agent.id,
      name: agent.name,
      role: agent.role,
      title: agent.title,
      status: agent.status,
      health_status: agent.health_status
    }
  end

  defp label(:critical), do: "Org risk"
  defp label(:warning), do: "Needs attention"
  defp label(:healthy), do: "Healthy"
  defp label(_), do: "Unknown"

  defp summary(:critical, metrics, missing_roles) do
    role_text =
      case missing_roles do
        [] -> "required reporting structure is incomplete"
        roles -> "missing #{Enum.map_join(roles, ", ", &role_label/1)} coverage"
      end

    "#{role_text}; #{metrics.detached_agents} detached #{plural(metrics.detached_agents, "agent")} need reassignment."
  end

  defp summary(:warning, metrics, _missing_roles) do
    demand =
      if metrics.role_demand_gaps > 0 do
        "#{metrics.role_demand_gaps} unstaffed #{plural(metrics.role_demand_gaps, "role")} across #{metrics.unstaffed_role_issues} open #{plural(metrics.unstaffed_role_issues, "issue")}, "
      else
        ""
      end

    "#{demand}#{metrics.overloaded_managers} overloaded #{plural(metrics.overloaded_managers, "manager")}, #{metrics.inactive_agents} inactive #{plural(metrics.inactive_agents, "agent")}, and #{metrics.degraded_agents} degraded #{plural(metrics.degraded_agents, "agent")} need attention."
  end

  defp summary(:healthy, metrics, _missing_roles) do
    "#{metrics.total_agents} active #{plural(metrics.total_agents, "agent")} with core leadership, delivery coverage, and manageable reporting span."
  end

  defp summary(_level, _metrics, _missing_roles), do: "Org health is not available."

  defp recommendations(
         _level,
         missing_roles,
         role_demand_gaps,
         detached,
         overloaded,
         inactive,
         degraded
       ) do
    [
      missing_role_recommendation(missing_roles),
      role_demand_recommendation(role_demand_gaps),
      detached_recommendation(detached),
      overloaded_recommendation(overloaded),
      inactive_recommendation(inactive),
      degraded_recommendation(degraded)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp missing_role_recommendation([]), do: nil

  defp missing_role_recommendation(roles) do
    %{
      severity: :critical,
      label: "Fill role coverage",
      detail:
        "Add or restore #{Enum.map_join(roles, ", ", &role_label/1)} coverage so company work has an accountable owner."
    }
  end

  defp role_demand_recommendation([]), do: nil

  defp role_demand_recommendation(gaps) do
    %{
      severity: :warning,
      label: "Staff queued work",
      detail:
        "Open issues need #{Enum.map_join(gaps, ", ", &role_gap_text/1)}; hire or assign those functions before broad dispatch."
    }
  end

  defp detached_recommendation([]), do: nil

  defp detached_recommendation(agents) do
    %{
      severity: :critical,
      label: "Reattach reports",
      detail:
        "#{length(agents)} #{plural(length(agents), "agent")} reference a missing or inactive manager; assign them to an active reporting line."
    }
  end

  defp overloaded_recommendation([]), do: nil

  defp overloaded_recommendation(agents) do
    %{
      severity: :warning,
      label: "Split manager span",
      detail:
        "#{length(agents)} #{plural(length(agents), "manager")} exceed #{@max_direct_reports} direct reports; add leads or redistribute reports."
    }
  end

  defp inactive_recommendation([]), do: nil

  defp inactive_recommendation(agents) do
    %{
      severity: :warning,
      label: "Restore inactive agents",
      detail:
        "#{length(agents)} #{plural(length(agents), "agent")} are paused, offline, or errored inside the active org."
    }
  end

  defp degraded_recommendation([]), do: nil

  defp degraded_recommendation(agents) do
    %{
      severity: :warning,
      label: "Repair adapter health",
      detail:
        "#{length(agents)} #{plural(length(agents), "agent")} have degraded or unavailable adapter health."
    }
  end

  defp role_label(:delivery), do: "delivery"
  defp role_label(role), do: Agent.role_label(role)

  defp issue_role_demand(company_id) do
    from(i in Issue,
      where:
        i.company_id == ^company_id and i.status in ^@demand_statuses and is_nil(i.hidden_at),
      select: %{
        id: i.id,
        identifier: i.identifier,
        title: i.title,
        description: i.description,
        assigned_role: i.assigned_role
      }
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn issue, acc ->
      case issue_role(issue) do
        role when role in @delivery_roles ->
          Map.update(acc, role, %{count: 1, examples: [issue_ref(issue)]}, fn demand ->
            demand
            |> Map.update!(:count, &(&1 + 1))
            |> Map.update!(:examples, &add_example(&1, issue_ref(issue)))
          end)

        _ ->
          acc
      end
    end)
  end

  defp issue_role(%{assigned_role: assigned_role} = issue) do
    Agent.normalize_role(assigned_role) ||
      Router.infer_role(%{
        title: issue.title,
        description: issue.description
      })
  end

  defp issue_ref(issue) do
    %{
      id: issue.id,
      identifier: issue.identifier,
      title: issue.title
    }
  end

  defp add_example(examples, %{id: id} = example) when is_binary(id) do
    examples
    |> Kernel.++([example])
    |> Enum.uniq_by(& &1.id)
    |> Enum.take(3)
  end

  defp add_example(examples, _example), do: examples

  defp role_demand_gaps(issue_role_demand, counts_by_role, active_agents) do
    issue_role_demand
    |> Enum.filter(fn {role, demand} ->
      demand.count > 0 and Map.get(counts_by_role, role, 0) == 0
    end)
    |> Enum.map(fn {role, demand} ->
      %{
        role: role,
        label: role_label(role),
        open_issues: demand.count,
        examples: demand.examples,
        suggested_parent: suggested_parent(role, active_agents)
      }
    end)
    |> Enum.sort_by(&{-&1.open_issues, &1.label})
  end

  defp suggested_parent(role, active_agents) do
    role
    |> manager_role_chain()
    |> Enum.reduce_while(nil, fn manager_role, _acc ->
      case first_agent_with_role(active_agents, manager_role) do
        nil -> {:cont, nil}
        agent -> {:halt, Map.take(agent_ref(agent), [:id, :name, :role, :title])}
      end
    end)
  end

  defp manager_role_chain(role) when role in [:engineer, :release_engineer, :qa_engineer],
    do: [:cto, :ceo]

  defp manager_role_chain(:product_manager), do: [:ceo]
  defp manager_role_chain(:designer), do: [:product_manager, :ceo]

  defp manager_role_chain(role)
       when role in [:researcher, :marketer, :content_strategist, :sales_development],
       do: [:product_manager, :ceo]

  defp manager_role_chain(:customer_support), do: [:product_manager, :ceo]
  defp manager_role_chain(_role), do: [:ceo]

  defp first_agent_with_role(active_agents, role) do
    active_agents
    |> Enum.filter(&(&1.role == role))
    |> Enum.sort_by(&String.downcase(&1.name || ""))
    |> List.first()
  end

  defp unstaffed_role_issue_count(role_demand_gaps) do
    Enum.reduce(role_demand_gaps, 0, &(&1.open_issues + &2))
  end

  defp role_gap_text(%{label: label, open_issues: count}) do
    "#{label} (#{count} #{plural(count, "issue")})"
  end

  defp plural(1, singular), do: singular
  defp plural(_count, singular), do: singular <> "s"
end
