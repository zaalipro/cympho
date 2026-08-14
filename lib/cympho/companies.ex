defmodule Cympho.Companies do
  import Ecto.Query, warn: false
  alias Cympho.Repo
  alias Cympho.Companies.Company
  alias Cympho.Companies.CompanyMembership
  alias Cympho.Companies.CompanyInvite
  alias Cympho.Companies.Portability
  alias Cympho.Companies.JoinRequest
  alias Cympho.Agents.{Agent, RolePlaybook}
  alias Cympho.BoardApprovals
  alias Cympho.Finances
  alias Cympho.GovernanceAuditLogs
  alias Cympho.Goals.Goal
  alias Cympho.Issues.Issue
  alias Cympho.Projects.Project
  alias Cympho.Secrets.Secret

  @runtime_mode_key "runtime_mode"
  @low_power_mode "low_power"
  # Safe default when callers omit budget_monthly_cents: $100/mo hard-stop.
  # Explicit 0/negative is rejected so autonomy cannot launch unbounded.
  @default_autonomous_budget_monthly_cents 10_000

  # CEO/CTO always hold these authorities via AgentActions' @governance_roles;
  # the flags exist so the agent permissions UI reflects that instead of
  # showing misleading "off" toggles.
  @governance_role_permissions %{
    "can_create_agents" => true,
    "can_assign_tasks" => true,
    "can_approve" => true
  }
  @company_runtime_pause_key "company_runtime_pause"
  @company_runtime_pause_source "global_runtime_control"

  # ── Company CRUD ──

  def list_companies do
    Company
    |> order_by([c], asc: c.inserted_at, asc: c.name)
    |> Repo.all()
  end

  def list_companies_page(opts \\ []) do
    Cympho.Pagination.page(Company,
      limit: Keyword.get(opts, :limit, 50),
      after: Keyword.get(opts, :after),
      cursor_fields: [{:inserted_at, :asc}, {:name, :asc}, {:id, :asc}]
    )
  end

  def list_companies_for_user(user_id) do
    Company
    |> join(:inner, [c], membership in CompanyMembership,
      on: membership.company_id == c.id and membership.user_id == ^user_id
    )
    |> order_by([c], asc: c.inserted_at, asc: c.name, asc: c.id)
    |> Repo.all()
  end

  def list_companies_for_user_page(user_id, opts \\ []) do
    Company
    |> join(:inner, [c], membership in CompanyMembership,
      on: membership.company_id == c.id and membership.user_id == ^user_id
    )
    |> Cympho.Pagination.page(
      limit: Keyword.get(opts, :limit, 50),
      after: Keyword.get(opts, :after),
      cursor_fields: [{:inserted_at, :asc}, {:name, :asc}, {:id, :asc}]
    )
  end

  def get_company!(id), do: Repo.get!(Company, id)

  def get_company_by_slug(slug) do
    Repo.get_by(Company, slug: slug)
  end

  def create_company(attrs \\ %{}) do
    %Company{}
    |> Company.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Creates a company and makes the given user its owner in one transaction.

  The owner also becomes a board member and uses the new company as their
  default workspace. This is the creation path for signed-in users; the plain
  `create_company/1` function remains available for imports, seeds, and tests
  that deliberately manage membership separately.
  """
  def create_company_for_owner(attrs, owner_user_id) do
    Repo.transaction(fn ->
      with {:ok, owner} <- Cympho.Users.get_user(owner_user_id),
           {:ok, company} <-
             %Company{}
             |> Company.changeset(attrs)
             |> Repo.insert(),
           {:ok, _membership} <-
             %CompanyMembership{}
             |> CompanyMembership.changeset(%{
               user_id: owner.id,
               company_id: company.id,
               role: "owner",
               is_board_member: true
             })
             |> Repo.insert(),
           {:ok, _owner} <-
             owner |> Ecto.Changeset.change(company_id: company.id) |> Repo.update() do
        company
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def update_company(%Company{} = company, attrs) do
    if policy_change_needs_approval?(company, attrs) do
      create_pending_policy_approval(company, attrs)
    else
      do_update_company(company, attrs)
    end
  end

  @doc """
  Updates a company directly, bypassing governance gates.
  Used by the approval executor to enact board-approved changes.
  """
  def execute_company_update(%Company{} = company, attrs) do
    persist_company_update(Company.changeset(company, attrs), attrs)
  end

  def update_governance_config(%Company{} = company, config) do
    attrs = %{governance_config: config}

    if policy_change_needs_approval?(company, attrs) do
      create_pending_policy_approval(company, attrs)
    else
      execute_company_update(company, attrs)
    end
  end

  def pause_company(%Company{} = company, reason \\ "Paused from dashboard") do
    case do_pause_company(company, reason, cancel_wakes?: false) do
      {:ok, updated, _runtime_stop} -> {:ok, updated}
      error -> error
    end
  end

  def pause_company_runtime(%Company{} = company, reason \\ "Paused from global runtime controls") do
    do_pause_company(company, reason, cancel_wakes?: false)
  end

  def stop_company_runtime(%Company{} = company, reason \\ "Stopped from global runtime controls") do
    do_pause_company(company, reason, cancel_wakes?: true)
  end

  def enter_low_power_mode(
        %Company{} = company,
        reason \\ "Low power from global runtime controls"
      ) do
    config =
      company
      |> Map.get(:governance_config)
      |> runtime_config()
      |> Map.merge(%{
        @runtime_mode_key => @low_power_mode,
        "runtime_mode_reason" => reason,
        "runtime_mode_started_at" =>
          DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      })

    with {:ok, updated} <- execute_company_update(company, %{governance_config: config}) do
      Cympho.PubSubGuard.company_broadcast(
        updated.id,
        "company",
        {:company_runtime_low_power, updated}
      )

      {:ok, updated}
    end
  end

  defp do_pause_company(%Company{} = company, reason, opts) do
    with {:ok, updated} <-
           execute_company_update(company, %{
             status: "paused",
             paused_at: DateTime.utc_now() |> DateTime.truncate(:second),
             paused_reason: reason
           }) do
      runtime_stop = stop_company_runtime_sessions(company.id, reason)
      runtime_stop = maybe_cancel_company_wakes(company.id, runtime_stop, reason, opts)
      pause_company_agents(company.id, reason)

      Cympho.PubSubGuard.company_broadcast(
        updated.id,
        "company",
        {:company_paused, updated}
      )

      Cympho.PubSubGuard.company_broadcast(
        updated.id,
        "company",
        {:company_runtime_stopped, updated, runtime_stop}
      )

      {:ok, updated, runtime_stop}
    end
  end

  defp maybe_cancel_company_wakes(company_id, runtime_stop, reason, opts) do
    if Keyword.get(opts, :cancel_wakes?, false) do
      {:ok, count} = Cympho.Wakes.cancel_company_wakes(company_id, reason)
      Map.put(runtime_stop, :wakes_cancelled, count)
    else
      Map.put_new(runtime_stop, :wakes_cancelled, 0)
    end
  end

  def resume_company(%Company{} = company) do
    with {:ok, updated} <-
           execute_company_update(company, %{
             status: "active",
             paused_at: nil,
             paused_reason: nil,
             governance_config: clear_runtime_mode(company.governance_config)
           }) do
      resume_company_agents(company.id)

      Cympho.PubSubGuard.company_broadcast(
        updated.id,
        "company",
        {:company_resumed, updated}
      )

      {:ok, updated}
    end
  end

  def active?(%Company{status: "active"}), do: true
  def active?(_company), do: false

  def runtime_mode(%Company{governance_config: config}) do
    case config do
      %{@runtime_mode_key => @low_power_mode} -> :low_power
      _ -> :standard
    end
  end

  def runtime_mode(company_id) when is_binary(company_id) do
    case Ecto.UUID.cast(company_id) do
      {:ok, valid_id} ->
        case Repo.get(Company, valid_id) do
          nil -> :standard
          company -> runtime_mode(company)
        end

      :error ->
        :standard
    end
  end

  def runtime_mode(_company), do: :standard

  def low_power?(company), do: runtime_mode(company) == :low_power

  @doc """
  Reads a runtime limit for a company from its `governance_config["limits"]`
  map, falling back to the supplied default. Used by the dispatcher and
  agent_actions to respect per-company concurrency / depth caps without
  needing a schema migration.

  Recognised keys (in `governance_config["limits"]`):
    * `"max_concurrent_runs"` — dispatcher concurrent agent dispatches
    * `"max_request_depth"` — sub-issue depth for agent decomposition
    * `"max_active_child_issues_per_parent"` — fan-out cap
  """
  @spec runtime_limit(Company.t() | binary() | nil, String.t(), term()) :: term()
  def runtime_limit(nil, _key, default), do: default

  def runtime_limit(%Company{governance_config: config}, key, default) do
    case config do
      %{"limits" => %{^key => value}} when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end

  def runtime_limit(company_id, key, default) when is_binary(company_id) do
    case Ecto.UUID.cast(company_id) do
      {:ok, valid_id} ->
        case Repo.get(Company, valid_id) do
          nil -> default
          company -> runtime_limit(company, key, default)
        end

      :error ->
        default
    end
  end

  def runtime_limit(_, _, default), do: default

  defp runtime_config(config) when is_map(config), do: config
  defp runtime_config(_config), do: %{}

  defp clear_runtime_mode(config) when is_map(config) do
    config
    |> Map.delete(@runtime_mode_key)
    |> Map.delete("runtime_mode_reason")
    |> Map.delete("runtime_mode_started_at")
  end

  defp clear_runtime_mode(_config), do: %{}

  defp stop_company_runtime_sessions(company_id, reason) do
    case Cympho.Orchestrator.Dispatcher.stop_company(company_id, reason) do
      {:ok, result} ->
        result

      {:error, reason} ->
        %{reason: "dispatcher_stop_failed", errors: [%{reason: inspect(reason)}]}
    end
  end

  defp pause_company_agents(company_id, reason) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    paused_at = DateTime.to_iso8601(now)

    from(a in Agent,
      where:
        a.company_id == ^company_id and a.governance_status != "terminated" and
          a.governance_status != "paused" and a.status != ^:paused
    )
    |> Repo.all()
    |> Enum.reduce(0, fn agent, count ->
      runtime_config =
        agent
        |> agent_runtime_config()
        |> Map.put(@company_runtime_pause_key, %{
          "source" => @company_runtime_pause_source,
          "reason" => reason,
          "paused_at" => paused_at,
          "previous_status" => agent.status && Atom.to_string(agent.status),
          "previous_governance_status" => agent.governance_status,
          "previous_governance_reasoning" => agent.governance_reasoning,
          "previous_pause_reason" => agent.pause_reason
        })

      agent
      |> Ecto.Changeset.change(%{
        governance_status: "paused",
        status: :paused,
        paused_at: now,
        pause_reason: reason,
        runtime_config: runtime_config
      })
      |> Repo.update()
      |> case do
        {:ok, _updated} -> count + 1
        {:error, _changeset} -> count
      end
    end)
  end

  defp resume_company_agents(company_id) do
    from(a in Agent,
      where: a.company_id == ^company_id and a.governance_status == "paused"
    )
    |> Repo.all()
    |> Enum.reduce(0, fn agent, count ->
      case company_runtime_pause_marker(agent) do
        %{"source" => @company_runtime_pause_source} = marker ->
          restore_company_paused_agent(agent, marker, count)

        _ ->
          count
      end
    end)
  end

  defp restore_company_paused_agent(agent, marker, count) do
    runtime_config =
      agent
      |> agent_runtime_config()
      |> Map.delete(@company_runtime_pause_key)

    attrs = %{
      governance_status: previous_governance_status(marker),
      governance_reasoning: marker["previous_governance_reasoning"],
      status: previous_agent_status(marker),
      paused_at: nil,
      pause_reason: marker["previous_pause_reason"],
      runtime_config: runtime_config
    }

    agent
    |> Ecto.Changeset.change(attrs)
    |> Repo.update()
    |> case do
      {:ok, _updated} -> count + 1
      {:error, _changeset} -> count
    end
  end

  defp company_runtime_pause_marker(%Agent{} = agent) do
    agent
    |> agent_runtime_config()
    |> Map.get(@company_runtime_pause_key)
  end

  defp agent_runtime_config(%Agent{runtime_config: config}) when is_map(config), do: config
  defp agent_runtime_config(_agent), do: %{}

  defp previous_governance_status(%{"previous_governance_status" => status})
       when is_binary(status) and status not in ["", "paused", "terminated"],
       do: status

  defp previous_governance_status(_marker), do: "active"

  defp previous_agent_status(%{"previous_status" => "running"}), do: :idle
  defp previous_agent_status(%{"previous_status" => "paused"}), do: :idle
  defp previous_agent_status(%{"previous_status" => "terminated"}), do: :idle

  defp previous_agent_status(%{"previous_status" => status}) when is_binary(status) do
    Enum.find(Agent.status_options(), :idle, &(Atom.to_string(&1) == status))
  end

  defp previous_agent_status(_marker), do: :idle

  defp do_update_company(%Company{} = company, attrs) do
    persist_company_update(Company.update_changeset(company, attrs), attrs)
  end

  defp persist_company_update(changeset, attrs) do
    changeset
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        GovernanceAuditLogs.log_action(
          "company_updated",
          nil,
          "Company updated: #{updated.name}",
          resource: updated,
          metadata: %{changes: Map.keys(attrs)}
        )

        Cympho.PubSubGuard.company_broadcast(
          updated.id,
          "company",
          {:company_updated, updated}
        )

        {:ok, updated}

      error ->
        error
    end
  end

  defp policy_change_needs_approval?(%Company{} = company, attrs) do
    governance_key_changing? =
      Map.has_key?(attrs, :governance_config) or Map.has_key?(attrs, "governance_config")

    governance_key_changing? and BoardApprovals.governance_required?(company, "policy_change")
  end

  defp create_pending_policy_approval(%Company{} = company, attrs) do
    new_config = attrs[:governance_config] || attrs["governance_config"] || %{}

    approval_attrs = %{
      title: "Company policy change approval: #{company.name}",
      description: "Governance config change requires board approval.",
      category: "policy_change",
      company_id: company.id,
      proposal_data: %{
        "action" => "update_company",
        "company_id" => company.id,
        "old_governance_config" => company.governance_config,
        "new_governance_config" => new_config,
        "update_attrs" => stringify_keys(attrs)
      }
    }

    BoardApprovals.create_board_approval(approval_attrs)
    |> case do
      {:ok, approval} ->
        GovernanceAuditLogs.log_action(
          "policy_change_pending_approval",
          nil,
          "Company config change pending board approval: #{company.name}",
          resource: approval,
          metadata: %{company_id: company.id}
        )

        {:pending_approval, approval}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp stringify_keys(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  def delete_company(%Company{} = company) do
    case Repo.delete(company) do
      {:ok, deleted} ->
        # Drop any EventStore topics scoped to this company so a long-running
        # node doesn't accumulate stale topic entries (e.g. from companies
        # created and deleted during testing or churn).
        _ = Cympho.EventStore.purge_topics_with_prefix("company:#{company.id}:")
        {:ok, deleted}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def change_company(%Company{} = company, attrs \\ %{}) do
    Company.changeset(company, attrs)
  end

  @autonomous_company_blueprints [
    %{
      key: "software",
      name: "Software product company",
      description: "CEO, CTO, product, design, and engineers for shipping a software product.",
      default_goal: "Build and run the business autonomously",
      default_prefix: "LLM",
      project_name: "Company OS",
      project_description: "Default operating project for autonomous company work.",
      company_description:
        "An autonomous AI software company with a CEO, CTO, product, design, and engineering team.",
      brand_color: "#D97757",
      role_summary: "CEO, CTO, Product, Design, Engineers",
      extra_agents: [],
      seed_issues: [
        %{
          title: "Create the first autonomous execution plan",
          description:
            "Break the company goal into CEO, CTO, product, design, and engineering work. Create follow-up issues for the first execution cycle.",
          priority: :critical,
          assignee: :ceo
        },
        %{
          title: "Set up the engineering environment and CI pipeline",
          description:
            "Establish the development environment, linting, formatting, and CI pipeline so engineers can ship reliably.",
          priority: :high,
          assignee: :cto
        },
        %{
          title: "Define the technical architecture",
          description:
            "Research and document the core technical architecture: stack choices, data model, API surface, and deployment strategy.",
          priority: :high,
          assignee: :cto
        },
        %{
          title: "Implement the first core feature",
          description:
            "Pick the highest-value feature from the execution plan and implement it end to end with tests.",
          priority: :medium,
          assignee: :first_engineer
        },
        %{
          title: "Ship a working demo for stakeholder review",
          description:
            "Package the first iteration into a reviewable demo. Document what works, what is missing, and what is next.",
          priority: :medium,
          assignee: :ceo
        }
      ]
    },
    %{
      key: "go_to_market",
      name: "Go-to-market company",
      description:
        "Research, content, demand generation, outbound, and support around one offer.",
      default_goal: "Launch a repeatable go-to-market motion for the offer",
      default_prefix: "GTM",
      project_name: "Growth OS",
      project_description:
        "Default project for market research, launch, sales, and support work.",
      company_description:
        "An autonomous AI growth company with research, marketing, sales, support, product, design, and technical execution.",
      brand_color: "#5E6AD2",
      role_summary: "CEO, Product, Research, Marketing, Content, Sales, Support",
      extra_agents: [
        %{
          ref: :research_lead,
          parent: :ceo,
          name: "Research Lead",
          title: "Market Research Lead",
          role: :researcher,
          capabilities: %{"market_research" => true, "competitor_analysis" => true},
          instructions:
            "Turn market, customer, and competitor ambiguity into decision-grade briefs for positioning and campaign choices."
        },
        %{
          ref: :growth_marketer,
          parent: :ceo,
          name: "Growth Marketer",
          title: "Growth Marketing Lead",
          role: :marketer,
          capabilities: %{"campaigns" => true, "positioning" => true},
          instructions:
            "Own channel experiments, launch messaging, audience hypotheses, and measurable growth plans."
        },
        %{
          ref: :content_strategist,
          parent: :growth_marketer,
          name: "Content Strategist",
          title: "Content Strategist",
          role: :content_strategist,
          capabilities: %{"editorial_calendar" => true, "copywriting" => true},
          instructions:
            "Convert positioning into briefs, drafts, calendars, and distribution-ready content."
        },
        %{
          ref: :sales_development,
          parent: :ceo,
          name: "Sales Development",
          title: "Sales Development Rep",
          role: :sales_development,
          capabilities: %{"prospecting" => true, "outreach" => true},
          instructions:
            "Research account lists, draft outbound sequences, and surface qualified pipeline decisions."
        },
        %{
          ref: :customer_support,
          parent: :product_lead,
          name: "Customer Support",
          title: "Customer Support Lead",
          role: :customer_support,
          capabilities: %{"support_docs" => true, "customer_feedback" => true},
          instructions:
            "Turn customer questions into support replies, docs updates, escalation notes, and product feedback."
        }
      ],
      seed_issues: [
        %{
          title: "Choose the first customer segment and wedge",
          description:
            "Use research and product input to pick the first ICP, pain point, and positioning wedge. Document the decision and tradeoffs.",
          priority: :critical,
          assignee: :ceo
        },
        %{
          title: "Research competitor positioning and audience language",
          description:
            "Create a concise market brief covering competitors, customer phrases, pricing signals, and proof points to reuse in campaigns.",
          priority: :high,
          assignee: :research_lead
        },
        %{
          title: "Draft the first launch campaign",
          description:
            "Turn the selected wedge into channel plan, message hierarchy, landing-page outline, and success metrics.",
          priority: :high,
          assignee: :growth_marketer
        },
        %{
          title: "Build the first outbound prospect list",
          description:
            "Define prospect filters, list the first accounts, draft outreach copy, and note qualification criteria.",
          priority: :medium,
          assignee: :sales_development
        },
        %{
          title: "Create the first support knowledge base skeleton",
          description:
            "Draft the initial FAQ, escalation rules, and product feedback loop for customers from the first campaign.",
          priority: :medium,
          assignee: :customer_support
        }
      ]
    },
    %{
      key: "product_discovery",
      name: "Product discovery company",
      description:
        "Product, design, research, QA, and engineering for validating a new product idea.",
      default_goal: "Validate the riskiest product assumptions with shippable evidence",
      default_prefix: "DISC",
      project_name: "Discovery OS",
      project_description:
        "Default project for discovery, prototyping, validation, and launch-readiness work.",
      company_description:
        "An autonomous AI product discovery company with research, product, design, QA, and engineering roles.",
      brand_color: "#14B8A6",
      role_summary: "CEO, Product, Design, Research, QA, CTO, Engineers",
      extra_agents: [
        %{
          ref: :research_lead,
          parent: :product_lead,
          name: "User Researcher",
          title: "User Researcher",
          role: :researcher,
          capabilities: %{"interview_synthesis" => true, "evidence_briefs" => true},
          instructions:
            "Turn customer, market, and usage evidence into concise product-risk briefs and decision recommendations."
        },
        %{
          ref: :qa_lead,
          parent: :cto,
          name: "QA Lead",
          title: "Quality Assurance Lead",
          role: :qa_engineer,
          capabilities: %{"test_planning" => true, "regression" => true},
          instructions:
            "Own validation evidence, acceptance-test plans, release risk notes, and focused regression checks."
        }
      ],
      seed_issues: [
        %{
          title: "Rank the top product risks",
          description:
            "List the riskiest assumptions, evidence needed, owner for each risk, and the smallest validation step.",
          priority: :critical,
          assignee: :product_lead
        },
        %{
          title: "Create the first discovery research brief",
          description:
            "Summarize target users, jobs to be done, competitor substitutes, and questions that would change the roadmap.",
          priority: :high,
          assignee: :research_lead
        },
        %{
          title: "Design the riskiest workflow prototype",
          description:
            "Produce a focused user flow, states, acceptance criteria, and implementation notes for the highest-risk workflow.",
          priority: :high,
          assignee: :design_lead
        },
        %{
          title: "Implement the first validation slice",
          description:
            "Build the smallest working slice that can validate the prototype and capture useful evidence.",
          priority: :medium,
          assignee: :first_engineer
        },
        %{
          title: "Define the validation test plan",
          description:
            "Turn the acceptance criteria into smoke checks, regression risks, and a release-readiness checklist.",
          priority: :medium,
          assignee: :qa_lead
        }
      ]
    },
    %{
      key: "support_ops",
      name: "Support operations company",
      description: "Support, QA, content, and product feedback loops for customer operations.",
      default_goal: "Run a responsive support operation that turns tickets into product signal",
      default_prefix: "SUP",
      project_name: "Support OS",
      project_description:
        "Default project for support queues, knowledge base work, QA, and feedback.",
      company_description:
        "An autonomous AI support operations company with customer support, QA, content, product, and technical escalation roles.",
      brand_color: "#0EA5E9",
      role_summary: "CEO, Product, Support, QA, Content, CTO",
      extra_agents: [
        %{
          ref: :customer_support,
          parent: :product_lead,
          name: "Support Lead",
          title: "Customer Support Lead",
          role: :customer_support,
          capabilities: %{"queue_triage" => true, "customer_feedback" => true},
          instructions:
            "Own customer replies, triage, escalation notes, knowledge base updates, and product feedback summaries."
        },
        %{
          ref: :qa_lead,
          parent: :cto,
          name: "Support QA",
          title: "Support Quality Analyst",
          role: :qa_engineer,
          capabilities: %{"support_quality" => true, "regression" => true},
          instructions:
            "Audit support resolutions, reproduce defects, and turn recurring issues into verifiable quality checks."
        },
        %{
          ref: :content_strategist,
          parent: :product_lead,
          name: "Knowledge Base Editor",
          title: "Knowledge Base Editor",
          role: :content_strategist,
          capabilities: %{"docs" => true, "faq" => true},
          instructions:
            "Turn support patterns into clear help-center articles, macros, FAQs, and internal support playbooks."
        }
      ],
      seed_issues: [
        %{
          title: "Define support triage and escalation rules",
          description:
            "Create severity levels, response targets, ownership rules, and escalation paths for customer issues.",
          priority: :critical,
          assignee: :customer_support
        },
        %{
          title: "Draft the first support macro and FAQ set",
          description:
            "Convert likely customer questions into reusable replies, FAQs, and links to product documentation.",
          priority: :high,
          assignee: :content_strategist
        },
        %{
          title: "Create a defect reproduction checklist",
          description:
            "Define what support must collect before escalating a bug to engineering, including environment and steps.",
          priority: :high,
          assignee: :qa_lead
        },
        %{
          title: "Map recurring support themes to product work",
          description:
            "Group the first support themes into product gaps, missing docs, usability issues, or engineering defects.",
          priority: :medium,
          assignee: :product_lead
        },
        %{
          title: "Prepare the first engineering escalation lane",
          description:
            "Define how confirmed defects reach the CTO, what evidence is required, and how customers are updated.",
          priority: :medium,
          assignee: :cto
        }
      ]
    },
    %{
      key: "content_studio",
      name: "Content studio company",
      description:
        "Editorial planning, research, design, and campaign publishing for a content engine.",
      default_goal:
        "Operate a consistent content engine that supports growth and customer education",
      default_prefix: "CNT",
      project_name: "Content OS",
      project_description:
        "Default project for research, editorial calendars, design assets, and publishing.",
      company_description:
        "An autonomous AI content studio with research, marketing, content strategy, design, and product input.",
      brand_color: "#DB2777",
      role_summary: "CEO, Research, Marketing, Content, Design, Product",
      extra_agents: [
        %{
          ref: :research_lead,
          parent: :product_lead,
          name: "Audience Researcher",
          title: "Audience Researcher",
          role: :researcher,
          capabilities: %{"audience_research" => true, "topic_research" => true},
          instructions:
            "Find audience questions, competitor content gaps, search intent, and source material for editorial decisions."
        },
        %{
          ref: :growth_marketer,
          parent: :ceo,
          name: "Distribution Lead",
          title: "Content Distribution Lead",
          role: :marketer,
          capabilities: %{"distribution" => true, "campaigns" => true},
          instructions:
            "Turn content into channel plans, launch calendars, measurement plans, and distribution experiments."
        },
        %{
          ref: :content_strategist,
          parent: :growth_marketer,
          name: "Managing Editor",
          title: "Managing Editor",
          role: :content_strategist,
          capabilities: %{"editorial_calendar" => true, "copywriting" => true},
          instructions:
            "Own the editorial calendar, briefs, drafts, review cycles, and publication-ready content packages."
        }
      ],
      seed_issues: [
        %{
          title: "Define the first editorial pillar set",
          description:
            "Choose 3-5 content pillars, target readers, business intent, and proof sources for each pillar.",
          priority: :critical,
          assignee: :content_strategist
        },
        %{
          title: "Research audience questions and content gaps",
          description:
            "Collect audience questions, competitor articles, missing angles, and reusable evidence for the first briefs.",
          priority: :high,
          assignee: :research_lead
        },
        %{
          title: "Draft the first campaign distribution plan",
          description:
            "Pick channels, cadence, CTAs, success metrics, and repurposing rules for the first content cycle.",
          priority: :high,
          assignee: :growth_marketer
        },
        %{
          title: "Design the reusable content asset system",
          description:
            "Define image, diagram, social, and landing-page asset patterns that support the first editorial cycle.",
          priority: :medium,
          assignee: :design_lead
        },
        %{
          title: "Connect content topics to product outcomes",
          description:
            "Map the editorial calendar to product education, sales enablement, customer onboarding, or research goals.",
          priority: :medium,
          assignee: :product_lead
        }
      ]
    },
    %{
      key: "sales_pipeline",
      name: "Sales pipeline company",
      description:
        "Prospecting, outbound, positioning, and customer handoff for repeatable sales motion.",
      default_goal: "Build a repeatable outbound pipeline with qualified sales opportunities",
      default_prefix: "SALE",
      project_name: "Sales OS",
      project_description:
        "Default project for target accounts, outreach, qualification, and handoff work.",
      company_description:
        "An autonomous AI sales pipeline company with sales development, research, marketing, support, and product alignment.",
      brand_color: "#16A34A",
      role_summary: "CEO, Sales, Research, Marketing, Product, Support",
      extra_agents: [
        %{
          ref: :sales_development,
          parent: :ceo,
          name: "Sales Development",
          title: "Sales Development Lead",
          role: :sales_development,
          capabilities: %{"prospecting" => true, "qualification" => true},
          instructions:
            "Own account research, prospect lists, outbound sequences, qualification rules, and pipeline updates."
        },
        %{
          ref: :research_lead,
          parent: :sales_development,
          name: "Account Researcher",
          title: "Account Researcher",
          role: :researcher,
          capabilities: %{"account_research" => true, "lead_research" => true},
          instructions:
            "Research accounts, buying triggers, personas, and objections that make outbound useful."
        },
        %{
          ref: :growth_marketer,
          parent: :ceo,
          name: "Sales Marketer",
          title: "Sales Enablement Marketer",
          role: :marketer,
          capabilities: %{"enablement" => true, "messaging" => true},
          instructions:
            "Turn positioning into outreach angles, proof points, and sales enablement assets."
        },
        %{
          ref: :customer_support,
          parent: :product_lead,
          name: "Customer Handoff",
          title: "Customer Handoff Lead",
          role: :customer_support,
          capabilities: %{"handoff" => true, "customer_context" => true},
          instructions:
            "Prepare handoff notes, customer expectations, and support readiness for qualified opportunities."
        }
      ],
      seed_issues: [
        %{
          title: "Define the first qualified account profile",
          description:
            "Set account filters, buyer roles, disqualifiers, urgency signals, and evidence needed before outreach.",
          priority: :critical,
          assignee: :sales_development
        },
        %{
          title: "Build the first target account list",
          description:
            "Research the first accounts, buyer hypotheses, trigger events, and personalization notes.",
          priority: :high,
          assignee: :research_lead
        },
        %{
          title: "Draft the first outbound sequence",
          description:
            "Create email and social touches with value proposition, proof points, objections, and CTAs.",
          priority: :high,
          assignee: :growth_marketer
        },
        %{
          title: "Define lead qualification and owner update rules",
          description:
            "Create the qualification checklist, follow-up cadence, and owner-facing weekly pipeline summary format.",
          priority: :medium,
          assignee: :sales_development
        },
        %{
          title: "Prepare customer handoff notes for won opportunities",
          description:
            "Define what support and product need before a sales opportunity becomes a customer relationship.",
          priority: :medium,
          assignee: :customer_support
        }
      ]
    },
    %{
      key: "research_lab",
      name: "Research lab company",
      description: "Decision-grade market, competitor, technical, and customer research briefs.",
      default_goal: "Produce decision-grade research that changes company priorities",
      default_prefix: "RES",
      project_name: "Research OS",
      project_description:
        "Default project for research questions, evidence briefs, and decisions.",
      company_description:
        "An autonomous AI research lab with researchers, product synthesis, content packaging, and executive decisions.",
      brand_color: "#7C3AED",
      role_summary: "CEO, Research, Product, Content, CTO",
      extra_agents: [
        %{
          ref: :research_lead,
          parent: :ceo,
          name: "Research Lead",
          title: "Research Lead",
          role: :researcher,
          capabilities: %{"market_research" => true, "technical_research" => true},
          instructions:
            "Own research questions, source quality, synthesis, uncertainty, and decision-grade recommendations."
        },
        %{
          ref: :content_strategist,
          parent: :research_lead,
          name: "Research Editor",
          title: "Research Editor",
          role: :content_strategist,
          capabilities: %{"briefs" => true, "editing" => true},
          instructions:
            "Turn raw research into concise briefs, source notes, summaries, and reusable decision packets."
        }
      ],
      seed_issues: [
        %{
          title: "Define the first research question backlog",
          description:
            "List high-leverage business, customer, competitor, and technical questions that could change priorities.",
          priority: :critical,
          assignee: :ceo
        },
        %{
          title: "Produce the first decision-grade research brief",
          description:
            "Answer the highest-priority question with sources, confidence, implications, and recommended next action.",
          priority: :high,
          assignee: :research_lead
        },
        %{
          title: "Package research into an owner-ready memo",
          description:
            "Edit the research into a concise memo with sources, risks, assumptions, and decision options.",
          priority: :high,
          assignee: :content_strategist
        },
        %{
          title: "Map research findings to product or engineering work",
          description:
            "Translate validated findings into product requirements, technical risks, or follow-up experiments.",
          priority: :medium,
          assignee: :product_lead
        },
        %{
          title: "Review technical implications from the research brief",
          description:
            "Have the CTO identify architecture, implementation, cost, or security implications from the research.",
          priority: :medium,
          assignee: :cto
        }
      ]
    },
    %{
      key: "qa_release",
      name: "QA and release company",
      description:
        "Quality assurance, release readiness, merge support, and customer-safe shipping.",
      default_goal: "Ship changes safely with clear QA, release, and rollback evidence",
      default_prefix: "REL",
      project_name: "Release OS",
      project_description:
        "Default project for QA plans, release gates, merge readiness, and rollout notes.",
      company_description:
        "An autonomous AI QA and release company with QA, release engineering, CTO review, product criteria, and implementation support.",
      brand_color: "#F59E0B",
      role_summary: "CEO, CTO, QA, Release, Product, Engineers",
      extra_agents: [
        %{
          ref: :qa_lead,
          parent: :cto,
          name: "QA Lead",
          title: "Quality Assurance Lead",
          role: :qa_engineer,
          capabilities: %{"test_planning" => true, "regression" => true},
          instructions:
            "Own acceptance checks, regression scope, release risk, smoke tests, and evidence quality."
        },
        %{
          ref: :release_engineer,
          parent: :cto,
          name: "Release Engineer",
          title: "Release Engineer",
          role: :release_engineer,
          capabilities: %{"merge" => true, "release" => true, "rollback" => true},
          instructions:
            "Own merge readiness, release notes, deployment checks, rollback notes, and post-release verification."
        }
      ],
      seed_issues: [
        %{
          title: "Define release readiness gates",
          description:
            "Create the required evidence, approvals, test results, and rollback notes before anything ships.",
          priority: :critical,
          assignee: :release_engineer
        },
        %{
          title: "Create the first QA smoke and regression plan",
          description:
            "Define smoke checks, regression areas, browser/device targets, and failure reporting rules.",
          priority: :high,
          assignee: :qa_lead
        },
        %{
          title: "Map product acceptance criteria to release checks",
          description:
            "Translate product acceptance criteria into release checklist items and owner-visible evidence.",
          priority: :high,
          assignee: :product_lead
        },
        %{
          title: "Prepare the first release notes template",
          description:
            "Define release notes, risk notes, migration notes, and customer communication format.",
          priority: :medium,
          assignee: :release_engineer
        },
        %{
          title: "Implement a small release pipeline verification task",
          description:
            "Have engineering add or verify one automated check that supports release confidence.",
          priority: :medium,
          assignee: :first_engineer
        }
      ]
    },
    %{
      key: "agency_delivery",
      name: "Agency delivery company",
      description:
        "Client intake, scoped delivery, design, engineering, QA, and account handoff.",
      default_goal: "Deliver client work predictably from brief to shipped outcome",
      default_prefix: "AGCY",
      project_name: "Agency OS",
      project_description: "Default project for client briefs, scoped delivery, QA, and handoff.",
      company_description:
        "An autonomous AI agency delivery company with client intake, product scoping, design, engineering, QA, and support handoff.",
      brand_color: "#EA580C",
      role_summary: "CEO, Product, Design, Engineering, QA, Support, Sales",
      extra_agents: [
        %{
          ref: :sales_development,
          parent: :ceo,
          name: "Client Intake",
          title: "Client Intake Lead",
          role: :sales_development,
          capabilities: %{"client_intake" => true, "scope_discovery" => true},
          instructions:
            "Turn client requests into intake notes, qualification, scope boundaries, and owner decision points."
        },
        %{
          ref: :qa_lead,
          parent: :cto,
          name: "Delivery QA",
          title: "Delivery QA Lead",
          role: :qa_engineer,
          capabilities: %{"acceptance_testing" => true, "handoff_review" => true},
          instructions:
            "Own acceptance tests, client-readiness checks, and delivery evidence before handoff."
        },
        %{
          ref: :customer_support,
          parent: :product_lead,
          name: "Client Success",
          title: "Client Success Lead",
          role: :customer_support,
          capabilities: %{"client_handoff" => true, "support" => true},
          instructions:
            "Own client handoff notes, support expectations, open questions, and follow-up issue intake."
        }
      ],
      seed_issues: [
        %{
          title: "Create the client intake and qualification checklist",
          description:
            "Define required client context, constraints, success criteria, scope risks, and disqualifiers.",
          priority: :critical,
          assignee: :sales_development
        },
        %{
          title: "Draft the first client-ready scope brief",
          description:
            "Turn the intake checklist into a concise scope, acceptance criteria, phases, and owner decision points.",
          priority: :high,
          assignee: :product_lead
        },
        %{
          title: "Design the first client deliverable flow",
          description:
            "Produce the flow, states, assets, and implementation notes for the first client-visible deliverable.",
          priority: :high,
          assignee: :design_lead
        },
        %{
          title: "Implement the first agency delivery slice",
          description:
            "Build the first client-visible slice with tests and a delivery note suitable for review.",
          priority: :medium,
          assignee: :first_engineer
        },
        %{
          title: "Prepare client handoff and QA evidence",
          description:
            "Create the acceptance checklist, QA notes, support handoff, and open-risk summary for delivery.",
          priority: :medium,
          assignee: :qa_lead
        }
      ]
    },
    %{
      key: "community_growth",
      name: "Community growth company",
      description: "Community research, content, campaigns, support loops, and product feedback.",
      default_goal: "Grow an engaged community that improves product and demand quality",
      default_prefix: "COMM",
      project_name: "Community OS",
      project_description:
        "Default project for community research, content, engagement, and feedback loops.",
      company_description:
        "An autonomous AI community growth company with research, marketing, content, support, and product feedback roles.",
      brand_color: "#0891B2",
      role_summary: "CEO, Research, Marketing, Content, Support, Product",
      extra_agents: [
        %{
          ref: :research_lead,
          parent: :product_lead,
          name: "Community Researcher",
          title: "Community Researcher",
          role: :researcher,
          capabilities: %{"community_research" => true, "member_insights" => true},
          instructions:
            "Identify community segments, member jobs, questions, rituals, and signals that should shape product and content."
        },
        %{
          ref: :growth_marketer,
          parent: :ceo,
          name: "Community Growth",
          title: "Community Growth Lead",
          role: :marketer,
          capabilities: %{"community_campaigns" => true, "engagement" => true},
          instructions:
            "Own community campaigns, onboarding loops, engagement experiments, and growth measurement."
        },
        %{
          ref: :content_strategist,
          parent: :growth_marketer,
          name: "Community Content",
          title: "Community Content Lead",
          role: :content_strategist,
          capabilities: %{"community_content" => true, "programming" => true},
          instructions:
            "Create prompts, announcements, event content, recaps, guides, and reusable community programming."
        },
        %{
          ref: :customer_support,
          parent: :product_lead,
          name: "Community Support",
          title: "Community Support Lead",
          role: :customer_support,
          capabilities: %{"member_support" => true, "feedback_triage" => true},
          instructions:
            "Turn community questions into replies, docs, product feedback, and escalation notes."
        }
      ],
      seed_issues: [
        %{
          title: "Define the first community segment and promise",
          description:
            "Choose who the community serves, what members get, contribution rules, and success signals.",
          priority: :critical,
          assignee: :ceo
        },
        %{
          title: "Research community questions and rituals",
          description:
            "Identify member questions, recurring topics, existing communities, and engagement patterns.",
          priority: :high,
          assignee: :research_lead
        },
        %{
          title: "Create the first community programming calendar",
          description:
            "Draft weekly prompts, events, content themes, announcements, and moderation expectations.",
          priority: :high,
          assignee: :content_strategist
        },
        %{
          title: "Launch the first member engagement experiment",
          description:
            "Define the first campaign, target members, call to action, measurement, and follow-up plan.",
          priority: :medium,
          assignee: :growth_marketer
        },
        %{
          title: "Create the member support and feedback loop",
          description:
            "Define how questions, feedback, and product signals move from community into support and product work.",
          priority: :medium,
          assignee: :customer_support
        }
      ]
    },
    %{
      key: "security_compliance",
      name: "Security compliance company",
      description:
        "Security reviews, compliance evidence, risk triage, and remediation tracking.",
      default_goal: "Maintain security and compliance evidence that can survive customer review",
      default_prefix: "SECA",
      project_name: "Security OS",
      project_description:
        "Default project for security reviews, compliance evidence, remediation, and audit notes.",
      company_description:
        "An autonomous AI security and compliance company with research, QA, CTO review, remediation, and evidence packaging.",
      brand_color: "#DC2626",
      role_summary: "CEO, CTO, Security Research, QA, Content, Engineers",
      extra_agents: [
        %{
          ref: :security_researcher,
          parent: :cto,
          name: "Security Researcher",
          title: "Security Researcher",
          role: :researcher,
          capabilities: %{"security_review" => true, "threat_modeling" => true},
          instructions:
            "Find security risks, map controls, review evidence, and produce decision-grade remediation notes."
        },
        %{
          ref: :compliance_qa,
          parent: :cto,
          name: "Compliance QA",
          title: "Compliance QA Lead",
          role: :qa_engineer,
          capabilities: %{"evidence_review" => true, "control_testing" => true},
          instructions:
            "Verify control evidence, test remediation claims, and flag gaps before customer or audit review."
        },
        %{
          ref: :security_docs,
          parent: :security_researcher,
          name: "Security Docs",
          title: "Security Documentation Lead",
          role: :content_strategist,
          capabilities: %{"security_docs" => true, "audit_packets" => true},
          instructions:
            "Turn technical security work into audit packets, customer-ready summaries, and internal runbooks."
        }
      ],
      seed_issues: [
        %{
          title: "Define the first security review scope",
          description:
            "Choose the systems, data classes, customer promises, controls, and risk thresholds for the first review.",
          priority: :critical,
          assignee: :ceo
        },
        %{
          title: "Create the first threat model and risk register",
          description:
            "Document assets, trust boundaries, likely threats, severity, owners, and remediation recommendations.",
          priority: :high,
          assignee: :security_researcher
        },
        %{
          title: "Verify compliance evidence for the top controls",
          description:
            "Check evidence quality for the first controls and list missing proof, stale proof, and remediation gaps.",
          priority: :high,
          assignee: :compliance_qa
        },
        %{
          title: "Plan the first remediation sprint",
          description:
            "Turn the highest-risk findings into engineering tasks with owner, acceptance criteria, and deadline.",
          priority: :medium,
          assignee: :cto
        },
        %{
          title: "Package a customer-ready security brief",
          description:
            "Create a concise brief covering posture, known risks, mitigations, and evidence links.",
          priority: :medium,
          assignee: :security_docs
        }
      ]
    },
    %{
      key: "data_insights",
      name: "Data insights company",
      description:
        "Metrics, research questions, analysis pipelines, and owner-ready insight briefs.",
      default_goal: "Turn operational data into weekly decisions and measurable experiments",
      default_prefix: "DATA",
      project_name: "Data OS",
      project_description:
        "Default project for metric definitions, analysis work, data quality, and insight briefs.",
      company_description:
        "An autonomous AI data insights company with analytics engineering, research synthesis, product framing, and executive reporting.",
      brand_color: "#2563EB",
      role_summary: "CEO, Product, Data Research, Analytics Engineering, Content",
      extra_agents: [
        %{
          ref: :data_researcher,
          parent: :product_lead,
          name: "Data Researcher",
          title: "Data Research Lead",
          role: :researcher,
          capabilities: %{"metric_research" => true, "analysis_planning" => true},
          instructions:
            "Turn business questions into metric definitions, analysis plans, assumptions, and decision thresholds."
        },
        %{
          ref: :analytics_engineer,
          parent: :cto,
          name: "Analytics Engineer",
          title: "Analytics Engineer",
          role: :engineer,
          capabilities: %{"data_pipelines" => true, "quality_checks" => true},
          instructions:
            "Implement lightweight data collection, transformations, quality checks, and reproducible analysis outputs."
        },
        %{
          ref: :insight_editor,
          parent: :data_researcher,
          name: "Insight Editor",
          title: "Insight Editor",
          role: :content_strategist,
          capabilities: %{"insight_briefs" => true, "executive_summaries" => true},
          instructions:
            "Convert analysis into concise insight briefs, charts narratives, and owner-ready recommendations."
        }
      ],
      seed_issues: [
        %{
          title: "Define the first decision metric tree",
          description:
            "Map the company goal to input metrics, output metrics, definitions, and owners.",
          priority: :critical,
          assignee: :product_lead
        },
        %{
          title: "Create the first analysis plan",
          description:
            "State the question, data needed, assumptions, caveats, and how the answer will change action.",
          priority: :high,
          assignee: :data_researcher
        },
        %{
          title: "Build the first data quality check",
          description:
            "Add or document one repeatable check that makes the first metric trustworthy enough to use.",
          priority: :high,
          assignee: :analytics_engineer
        },
        %{
          title: "Draft the first weekly insight brief",
          description:
            "Package metric movement, explanation, confidence, and recommended experiment into an owner brief.",
          priority: :medium,
          assignee: :insight_editor
        },
        %{
          title: "Turn insights into a decision backlog",
          description:
            "Create the first ranked list of actions, experiments, or product changes implied by the analysis.",
          priority: :medium,
          assignee: :ceo
        }
      ]
    },
    %{
      key: "finance_ops",
      name: "Finance operations company",
      description:
        "Budget controls, spend reviews, vendor tracking, and forecast-ready owner updates.",
      default_goal:
        "Keep spend, forecast, vendors, and ROI visible before money becomes a surprise",
      default_prefix: "FIN",
      project_name: "Finance OS",
      project_description:
        "Default project for budget posture, vendor reviews, spend evidence, and financial decisions.",
      company_description:
        "An autonomous AI finance operations company with research, executive reporting, vendor tracking, and operational controls.",
      brand_color: "#059669",
      role_summary: "CEO, Research, Content, Product, Support, CTO",
      extra_agents: [
        %{
          ref: :finance_researcher,
          parent: :ceo,
          name: "Finance Researcher",
          title: "Finance Research Lead",
          role: :researcher,
          capabilities: %{"spend_analysis" => true, "vendor_research" => true},
          instructions:
            "Research spend patterns, vendor options, pricing risk, and financial assumptions for owner decisions."
        },
        %{
          ref: :finance_editor,
          parent: :finance_researcher,
          name: "Finance Editor",
          title: "Finance Reporting Lead",
          role: :content_strategist,
          capabilities: %{"finance_briefs" => true, "reporting" => true},
          instructions:
            "Turn finance findings into concise owner updates, variance notes, and decision packets."
        },
        %{
          ref: :vendor_support,
          parent: :product_lead,
          name: "Vendor Support",
          title: "Vendor Support Lead",
          role: :customer_support,
          capabilities: %{"vendor_tracking" => true, "renewal_notes" => true},
          instructions:
            "Track vendor questions, renewal risks, support issues, and follow-up commitments."
        }
      ],
      seed_issues: [
        %{
          title: "Create the first budget posture review",
          description:
            "Summarize current budget, spend assumptions, expected burn, and the first owner-visible risk.",
          priority: :critical,
          assignee: :ceo
        },
        %{
          title: "Research the highest-risk vendor or cost center",
          description:
            "Identify cost driver, alternatives, contract risk, usage assumptions, and recommended action.",
          priority: :high,
          assignee: :finance_researcher
        },
        %{
          title: "Draft the weekly finance owner update",
          description:
            "Create a short finance brief with spend movement, forecast risk, vendor notes, and decisions needed.",
          priority: :high,
          assignee: :finance_editor
        },
        %{
          title: "Map finance risk to product or engineering choices",
          description:
            "Identify product, infrastructure, or vendor decisions that could improve margin or reduce risk.",
          priority: :medium,
          assignee: :product_lead
        },
        %{
          title: "Prepare vendor follow-up and support notes",
          description:
            "List vendor questions, renewal dates, support blockers, and owner-ready follow-up actions.",
          priority: :medium,
          assignee: :vendor_support
        }
      ]
    },
    %{
      key: "devtools_platform",
      name: "Developer tools company",
      description: "Developer experience, platform docs, SDK quality, QA, and release readiness.",
      default_goal: "Ship developer tooling that is easy to adopt, verify, and support",
      default_prefix: "DEV",
      project_name: "DevTools OS",
      project_description:
        "Default project for SDKs, docs, examples, QA, release notes, and developer feedback.",
      company_description:
        "An autonomous AI developer tools company with product, engineering, design, QA, release, docs, and developer advocacy.",
      brand_color: "#4F46E5",
      role_summary: "CEO, Product, CTO, Engineers, QA, Release, Marketing",
      extra_agents: [
        %{
          ref: :developer_advocate,
          parent: :product_lead,
          name: "Developer Advocate",
          title: "Developer Advocate",
          role: :marketer,
          capabilities: %{"developer_education" => true, "examples" => true},
          instructions:
            "Turn product and engineering work into adoption paths, examples, launch notes, and developer feedback."
        },
        %{
          ref: :platform_qa,
          parent: :cto,
          name: "Platform QA",
          title: "Platform QA Lead",
          role: :qa_engineer,
          capabilities: %{"sdk_testing" => true, "compatibility" => true},
          instructions:
            "Verify SDK flows, examples, docs accuracy, compatibility, and release-readiness evidence."
        },
        %{
          ref: :release_engineer,
          parent: :cto,
          name: "Release Engineer",
          title: "Release Engineer",
          role: :release_engineer,
          capabilities: %{"package_release" => true, "changelog" => true},
          instructions:
            "Own package readiness, changelogs, versioning, rollback notes, and post-release verification."
        }
      ],
      seed_issues: [
        %{
          title: "Define the first developer adoption path",
          description:
            "Choose the target developer, first successful outcome, setup path, examples, and success metric.",
          priority: :critical,
          assignee: :product_lead
        },
        %{
          title: "Design the first SDK or API quickstart",
          description:
            "Draft the quickstart flow, code path, error states, and documentation requirements.",
          priority: :high,
          assignee: :developer_advocate
        },
        %{
          title: "Implement the first developer tooling slice",
          description:
            "Build or improve the smallest SDK, CLI, API, or example path that proves the adoption flow.",
          priority: :high,
          assignee: :first_engineer
        },
        %{
          title: "Verify the quickstart end to end",
          description:
            "Run the quickstart as a new developer and capture every failure, ambiguity, and missing check.",
          priority: :medium,
          assignee: :platform_qa
        },
        %{
          title: "Prepare developer release notes and rollback plan",
          description:
            "Create changelog, migration notes, known issues, and post-release verification steps.",
          priority: :medium,
          assignee: :release_engineer
        }
      ]
    },
    %{
      key: "incident_response",
      name: "Incident response company",
      description: "Incident triage, customer communication, remediation, and postmortem loops.",
      default_goal:
        "Resolve incidents quickly with clear ownership, evidence, and customer updates",
      default_prefix: "INC",
      project_name: "Incident OS",
      project_description:
        "Default project for incident response, remediation, communications, and postmortems.",
      company_description:
        "An autonomous AI incident response company with CTO command, QA reproduction, engineering remediation, support, and communications.",
      brand_color: "#B45309",
      role_summary: "CEO, CTO, QA, Engineering, Support, Content",
      extra_agents: [
        %{
          ref: :incident_qa,
          parent: :cto,
          name: "Incident QA",
          title: "Incident QA Lead",
          role: :qa_engineer,
          capabilities: %{"reproduction" => true, "verification" => true},
          instructions:
            "Reproduce incidents, define impact, verify fixes, and maintain the incident evidence trail."
        },
        %{
          ref: :incident_comms,
          parent: :ceo,
          name: "Incident Comms",
          title: "Incident Communications Lead",
          role: :content_strategist,
          capabilities: %{"status_updates" => true, "postmortems" => true},
          instructions:
            "Write internal status updates, customer communications, postmortems, and owner-ready incident summaries."
        },
        %{
          ref: :customer_support,
          parent: :product_lead,
          name: "Customer Support",
          title: "Customer Support Lead",
          role: :customer_support,
          capabilities: %{"customer_updates" => true, "ticket_triage" => true},
          instructions:
            "Coordinate affected customer notes, support replies, escalation details, and follow-up tracking."
        }
      ],
      seed_issues: [
        %{
          title: "Define incident severity and command rules",
          description:
            "Create severity levels, command owner, update cadence, decision rights, and escalation thresholds.",
          priority: :critical,
          assignee: :cto
        },
        %{
          title: "Build the first incident reproduction checklist",
          description:
            "Define what evidence is needed to reproduce, scope, verify, and close an incident.",
          priority: :high,
          assignee: :incident_qa
        },
        %{
          title: "Prepare the first remediation lane",
          description:
            "Create a focused engineering issue template for incident fixes, validation, and rollback notes.",
          priority: :high,
          assignee: :first_engineer
        },
        %{
          title: "Draft status update and postmortem templates",
          description:
            "Create customer-safe status updates, internal executive updates, and postmortem sections.",
          priority: :medium,
          assignee: :incident_comms
        },
        %{
          title: "Set customer follow-up and support tracking rules",
          description:
            "Define how affected customers are tracked, updated, resolved, and included in the post-incident review.",
          priority: :medium,
          assignee: :customer_support
        }
      ]
    },
    %{
      key: "partnerships",
      name: "Partnerships company",
      description:
        "Partner research, co-marketing, outbound, enablement, and handoff operations.",
      default_goal:
        "Build a partner pipeline that creates qualified distribution and product leverage",
      default_prefix: "PART",
      project_name: "Partnerships OS",
      project_description:
        "Default project for partner research, outreach, co-marketing, qualification, and handoff.",
      company_description:
        "An autonomous AI partnerships company with research, sales development, marketing, product fit, and customer handoff.",
      brand_color: "#9333EA",
      role_summary: "CEO, Sales, Research, Marketing, Product, Support",
      extra_agents: [
        %{
          ref: :partner_researcher,
          parent: :ceo,
          name: "Partner Researcher",
          title: "Partner Research Lead",
          role: :researcher,
          capabilities: %{"partner_research" => true, "market_mapping" => true},
          instructions:
            "Find partner categories, target accounts, mutual value, risks, and proof needed for outreach."
        },
        %{
          ref: :sales_development,
          parent: :ceo,
          name: "Partner Development",
          title: "Partner Development Lead",
          role: :sales_development,
          capabilities: %{"partner_outreach" => true, "qualification" => true},
          instructions:
            "Own partner outreach, qualification, next steps, pipeline notes, and decision-ready owner updates."
        },
        %{
          ref: :partner_marketer,
          parent: :sales_development,
          name: "Partner Marketer",
          title: "Partner Marketing Lead",
          role: :marketer,
          capabilities: %{"co_marketing" => true, "enablement" => true},
          instructions:
            "Create co-marketing angles, partner enablement assets, campaign plans, and launch measurement."
        },
        %{
          ref: :customer_support,
          parent: :product_lead,
          name: "Partner Handoff",
          title: "Partner Handoff Lead",
          role: :customer_support,
          capabilities: %{"handoff" => true, "partner_support" => true},
          instructions:
            "Prepare partner handoff notes, implementation questions, support expectations, and follow-up rules."
        }
      ],
      seed_issues: [
        %{
          title: "Define the first partner thesis",
          description:
            "Choose partner categories, mutual value, target users, disqualifiers, and success criteria.",
          priority: :critical,
          assignee: :ceo
        },
        %{
          title: "Research the first partner target list",
          description:
            "Build a ranked partner list with fit, contact angle, expected value, and known risks.",
          priority: :high,
          assignee: :partner_researcher
        },
        %{
          title: "Draft partner outreach and qualification flow",
          description:
            "Create outreach copy, discovery questions, qualification fields, and next-step rules.",
          priority: :high,
          assignee: :sales_development
        },
        %{
          title: "Create the first co-marketing concept",
          description:
            "Define offer, message, channels, launch steps, and measurement for a partner campaign.",
          priority: :medium,
          assignee: :partner_marketer
        },
        %{
          title: "Prepare partner implementation handoff notes",
          description:
            "List integration needs, support promises, product gaps, and customer-facing follow-up steps.",
          priority: :medium,
          assignee: :customer_support
        }
      ]
    },
    %{
      key: "training_academy",
      name: "Training academy company",
      description: "Curriculum, enablement content, learner support, and adoption measurement.",
      default_goal: "Create a training engine that turns knowledge into measurable user adoption",
      default_prefix: "TRAIN",
      project_name: "Academy OS",
      project_description:
        "Default project for curriculum, lessons, enablement campaigns, learner support, and feedback.",
      company_description:
        "An autonomous AI training academy with curriculum research, content production, enablement, support, product feedback, and technical setup.",
      brand_color: "#0F766E",
      role_summary: "CEO, Research, Content, Marketing, Support, Product",
      extra_agents: [
        %{
          ref: :curriculum_researcher,
          parent: :product_lead,
          name: "Curriculum Researcher",
          title: "Curriculum Research Lead",
          role: :researcher,
          capabilities: %{"learning_research" => true, "curriculum_mapping" => true},
          instructions:
            "Identify learner segments, prerequisites, gaps, outcomes, and the smallest useful curriculum path."
        },
        %{
          ref: :instructional_content,
          parent: :curriculum_researcher,
          name: "Instructional Content",
          title: "Instructional Content Lead",
          role: :content_strategist,
          capabilities: %{"lesson_design" => true, "enablement_content" => true},
          instructions:
            "Create lessons, exercises, checklists, examples, and assessment-ready training content."
        },
        %{
          ref: :enablement_marketer,
          parent: :ceo,
          name: "Enablement Marketer",
          title: "Enablement Marketing Lead",
          role: :marketer,
          capabilities: %{"adoption_campaigns" => true, "activation" => true},
          instructions:
            "Launch training programs, drive participation, measure activation, and package adoption wins."
        },
        %{
          ref: :learner_support,
          parent: :product_lead,
          name: "Learner Support",
          title: "Learner Support Lead",
          role: :customer_support,
          capabilities: %{"learner_support" => true, "feedback_triage" => true},
          instructions:
            "Answer learner questions, identify stuck points, capture feedback, and route product or curriculum gaps."
        }
      ],
      seed_issues: [
        %{
          title: "Define the first learner outcome and path",
          description:
            "Choose the learner, target skill, prerequisite knowledge, success evidence, and minimum lesson path.",
          priority: :critical,
          assignee: :curriculum_researcher
        },
        %{
          title: "Draft the first training module",
          description:
            "Create lesson outline, exercises, examples, checks for understanding, and completion criteria.",
          priority: :high,
          assignee: :instructional_content
        },
        %{
          title: "Design the training adoption campaign",
          description:
            "Define launch audience, message, cadence, participation target, and activation metrics.",
          priority: :high,
          assignee: :enablement_marketer
        },
        %{
          title: "Create learner support and feedback routing",
          description:
            "Define support replies, escalation rules, feedback tags, and product or curriculum follow-up paths.",
          priority: :medium,
          assignee: :learner_support
        },
        %{
          title: "Prepare the technical setup checklist",
          description:
            "List environment, access, sample data, and verification steps learners need before the module.",
          priority: :medium,
          assignee: :cto
        }
      ]
    }
  ]

  @doc """
  Lists the autonomous company blueprints available to onboarding and the CLI.
  """
  def autonomous_company_blueprints do
    Enum.map(@autonomous_company_blueprints, &public_blueprint/1)
  end

  def autonomous_company_blueprint(key) do
    case find_autonomous_company_blueprint(key) do
      nil -> {:error, :not_found}
      blueprint -> {:ok, public_blueprint(blueprint)}
    end
  end

  def autonomous_company_blueprint_manifest(key, opts \\ []) do
    case find_autonomous_company_blueprint(key) do
      nil ->
        {:error, :not_found}

      blueprint ->
        engineer_count =
          opts
          |> Keyword.get(:engineer_count, 2)
          |> normalize_engineer_count()

        {:ok, blueprint_launch_manifest(blueprint, engineer_count)}
    end
  end

  @doc """
  Creates a Paperclip-style autonomous starter company.

  The template creates a company, one project, one top-level company goal, a CEO,
  CTO, role-specific agents, then queues the blueprint's first strategy issues.
  It is intentionally local-trusted: no user account is required.

  Always inserts a company-scoped `Finances.BudgetPolicy` with
  `action_on_exceed: "block"` so runtime hard-stop (`check_runtime_budget/2`)
  cannot be skipped. `budget_monthly_cents` must be positive when provided;
  when omitted, a safe default (`#{@default_autonomous_budget_monthly_cents}`
  cents) is applied. Explicit `0` fails closed with `{:error, :budget_required}`.
  """
  def create_autonomous_company(attrs \\ %{}) do
    with {:ok, budget_monthly_cents} <- resolve_autonomous_budget_monthly_cents(attrs) do
      do_create_autonomous_company(attrs, budget_monthly_cents)
    end
  end

  defp do_create_autonomous_company(attrs, budget_monthly_cents) do
    blueprint =
      attrs
      |> blueprint_key_from_attrs()
      |> find_autonomous_company_blueprint()
      |> case do
        nil -> find_autonomous_company_blueprint("software")
        blueprint -> blueprint
      end

    name = attrs[:name] || attrs["name"] || "Autonomous Software Company"

    goal_title =
      attrs[:goal_title] || attrs["goal_title"] || blueprint.default_goal

    requested_prefix = attrs[:issue_prefix] || attrs["issue_prefix"] || blueprint.default_prefix
    issue_prefix = unique_project_prefix(requested_prefix)

    engineer_count =
      normalize_engineer_count(attrs[:engineer_count] || attrs["engineer_count"] || 2)

    adapter = normalize_adapter(attrs[:adapter] || attrs["adapter"] || :claude_code)

    project_name =
      normalize_project_name(attrs[:project_name] || attrs["project_name"], blueprint)

    owner_user_id = attrs[:owner_user_id] || attrs["owner_user_id"]
    engineer_names = normalize_engineer_names(attrs[:engineer_names] || attrs["engineer_names"])

    agent_runtime =
      normalize_agent_runtime(attrs[:agent_runtime] || attrs["agent_runtime"], adapter)

    role_runtimes =
      normalize_role_runtimes(
        attrs[:role_runtimes] || attrs["role_runtimes"],
        adapter,
        agent_runtime
      )

    {ceo_adapter, ceo_runtime} = role_runtimes["ceo"]
    {cto_adapter, cto_runtime} = role_runtimes["cto"]
    {engineer_adapter, engineer_runtime} = role_runtimes["engineer"]
    seed_issue_count = length(blueprint.seed_issues)
    launch_manifest = blueprint_launch_manifest(blueprint, engineer_count)

    Repo.transaction(fn ->
      company =
        %Company{}
        |> Company.changeset(%{
          name: name,
          slug: unique_slug(name),
          description: blueprint.company_description,
          status: "active",
          issue_prefix: issue_prefix,
          # Pre-aligned with the seed issues created below; otherwise the
          # next Issues.create_issue/1 call would collide on issue_number.
          issue_counter: seed_issue_count,
          budget_monthly_cents: budget_monthly_cents,
          require_board_approval_for_new_agents: false,
          governance_config: %{
            "autonomy_mode" => "autonomous_default",
            "approval_gates" => ["budget_override", "dangerous_runtime_action"],
            "company_blueprint" => blueprint.key,
            "company_blueprint_manifest" => launch_manifest
          },
          brand_color: blueprint.brand_color
        })
        |> Repo.insert!()

      # Runtime hard-stop only reads Finances.BudgetPolicy — company.budget_monthly_cents
      # alone would leave first-run autonomy unbounded.
      budget_policy = insert_autonomous_block_budget_policy!(company.id, budget_monthly_cents)

      # Resolve the owner before inserting the membership: the membership
      # changeset carries assoc_constraint(:user), so inserting first would
      # raise Ecto.InvalidChangesetError on the FK instead of reaching the
      # {:error, :owner_not_found} rollback contract.
      if owner_user_id do
        case Cympho.Users.get_user(owner_user_id) do
          {:ok, user} ->
            %CompanyMembership{}
            |> CompanyMembership.changeset(%{
              user_id: owner_user_id,
              company_id: company.id,
              role: "owner",
              is_board_member: true
            })
            |> Repo.insert!()

            user |> Ecto.Changeset.change(company_id: company.id) |> Repo.update!()

          {:error, :not_found} ->
            Repo.rollback(:owner_not_found)
        end
      end

      project =
        %Project{}
        |> Project.changeset(%{
          company_id: company.id,
          name: project_name,
          description: blueprint.project_description,
          prefix: issue_prefix,
          status: :active,
          settings: %{
            "wip_limits" => %{
              "in_progress" => engineer_count + length(blueprint.extra_agents) + 2
            }
          }
        })
        |> Repo.insert!()

      goal =
        %Goal{}
        |> Goal.changeset(%{
          company_id: company.id,
          project_id: project.id,
          title: goal_title,
          description: "Top-level company objective. CEO decomposes this into executable work.",
          priority: "critical",
          status: "active"
        })
        |> Repo.insert!()

      ceo =
        create_template_agent!(%{
          company_id: company.id,
          project_id: project.id,
          name: "CEO",
          title: "Chief Executive Officer",
          role: :ceo,
          adapter: ceo_adapter,
          runtime_config: ceo_runtime,
          max_concurrent_jobs: 1,
          # Governance roles always hold these authorities in AgentActions;
          # setting the flags keeps the permissions UI truthful.
          permissions: @governance_role_permissions,
          capabilities: %{
            "strategy" => true,
            "planning" => true,
            "budgeting" => true,
            "hiring" => true
          },
          instructions:
            "Own the company goal, break strategy into goals and issues, delegate product criteria to Product, experience work to Design, technical execution to the CTO, and keep the company running without waiting for humans unless a configured governance gate is hit."
        })

      cto =
        create_template_agent!(%{
          company_id: company.id,
          project_id: project.id,
          parent_id: ceo.id,
          created_by_agent_id: ceo.id,
          name: "CTO",
          title: "Chief Technology Officer",
          role: :cto,
          adapter: cto_adapter,
          runtime_config: cto_runtime,
          max_concurrent_jobs: 2,
          permissions: @governance_role_permissions,
          capabilities: %{
            "architecture" => true,
            "review" => true,
            "triage" => true,
            "technical_planning" => true
          },
          instructions:
            "Translate CEO strategy into technical plans, review engineering work, unblock engineers, and maintain execution quality."
        })

      engineers =
        if engineer_count > 0 do
          for index <- 1..engineer_count do
            create_template_agent!(%{
              company_id: company.id,
              project_id: project.id,
              parent_id: cto.id,
              created_by_agent_id: cto.id,
              name: engineer_name(engineer_names, index),
              title: "Software Engineer",
              role: :engineer,
              adapter: engineer_adapter,
              runtime_config: engineer_runtime,
              max_concurrent_jobs: 1,
              capabilities: %{
                "implementation" => true,
                "testing" => true,
                "debugging" => true
              },
              instructions:
                "Implement assigned issues end to end, leave comments with results, and surface blockers explicitly."
            })
          end
        else
          []
        end

      product_lead =
        create_template_agent!(%{
          company_id: company.id,
          project_id: project.id,
          parent_id: ceo.id,
          created_by_agent_id: ceo.id,
          name: "Product Lead",
          title: "Product Lead",
          role: :product_manager,
          adapter: adapter,
          runtime_config: agent_runtime,
          max_concurrent_jobs: 1,
          capabilities: %{
            "acceptance_criteria" => true,
            "prioritization" => true,
            "stakeholder_alignment" => true
          },
          instructions:
            "Turn owner intent into crisp acceptance criteria, user stories, dependencies, and definitions of done for the CEO and CTO."
        })

      design_lead =
        create_template_agent!(%{
          company_id: company.id,
          project_id: project.id,
          parent_id: ceo.id,
          created_by_agent_id: ceo.id,
          name: "Design Lead",
          title: "Design Lead",
          role: :designer,
          adapter: adapter,
          runtime_config: agent_runtime,
          max_concurrent_jobs: 1,
          capabilities: %{
            "user_flows" => true,
            "interaction_design" => true,
            "visual_specs" => true
          },
          instructions:
            "Produce user flows, interaction states, accessibility notes, and implementation-ready design specs for engineering."
        })

      first_engineer = List.first(engineers, cto)

      base_refs = %{
        ceo: ceo,
        cto: cto,
        product_lead: product_lead,
        design_lead: design_lead,
        first_engineer: first_engineer
      }

      {extra_agents, agent_refs} =
        create_blueprint_extra_agents!(blueprint.extra_agents, base_refs, %{
          company_id: company.id,
          project_id: project.id,
          adapter: adapter,
          runtime_config: agent_runtime
        })

      seed_specs = blueprint_seed_specs(blueprint, agent_refs)

      seed_issues =
        for spec <- seed_specs do
          %Issue{}
          |> Issue.changeset(%{
            company_id: company.id,
            project_id: project.id,
            goal_id: goal.id,
            assignee_id: spec.assignee_id,
            issue_number: spec.number,
            identifier: "#{issue_prefix}-#{spec.number}",
            title: spec.title,
            description: spec.description,
            status: :todo,
            priority: spec.priority,
            assigned_role: spec.assigned_role,
            origin_type: "onboarding",
            request_depth: 0
          })
          |> Repo.insert!()
        end

      %{
        company: company,
        project: project,
        goal: goal,
        blueprint: public_blueprint(blueprint),
        agents: [ceo, cto | engineers] ++ [product_lead, design_lead] ++ extra_agents,
        seed_issues: seed_issues,
        budget_policy: budget_policy
      }
    end)
  end

  # Positive monthly limit required for autonomy. Missing → safe default; 0 → fail closed.
  defp resolve_autonomous_budget_monthly_cents(attrs) when is_map(attrs) do
    raw =
      cond do
        Map.has_key?(attrs, :budget_monthly_cents) -> Map.get(attrs, :budget_monthly_cents)
        Map.has_key?(attrs, "budget_monthly_cents") -> Map.get(attrs, "budget_monthly_cents")
        true -> :missing
      end

    case normalize_budget_monthly_cents(raw) do
      :missing ->
        {:ok, @default_autonomous_budget_monthly_cents}

      cents when is_integer(cents) and cents > 0 ->
        {:ok, cents}

      _ ->
        {:error, :budget_required}
    end
  end

  defp normalize_budget_monthly_cents(:missing), do: :missing
  defp normalize_budget_monthly_cents(nil), do: :missing
  defp normalize_budget_monthly_cents(""), do: :missing
  defp normalize_budget_monthly_cents(cents) when is_integer(cents), do: cents

  defp normalize_budget_monthly_cents(%Decimal{} = cents) do
    cents |> Decimal.round(0) |> Decimal.to_integer()
  end

  defp normalize_budget_monthly_cents(cents) when is_float(cents), do: trunc(cents)

  defp normalize_budget_monthly_cents(cents) when is_binary(cents) do
    trimmed = String.trim(cents)

    case Integer.parse(trimmed) do
      {n, ""} -> n
      _ -> :invalid
    end
  end

  defp normalize_budget_monthly_cents(_), do: :invalid

  # Intentionally omits budget_id: this is the unowned onboarding company
  # hard-stop. UI Budgets create/sync/delete match by budget_id ownership and
  # must not claim or deactivate this policy via company-scope collision.
  defp insert_autonomous_block_budget_policy!(company_id, budget_monthly_cents) do
    case Finances.create_budget_policy(%{
           company_id: company_id,
           scope: "company",
           period: "monthly",
           budget_limit_usd: budget_cents_to_usd(budget_monthly_cents),
           warning_threshold_pct: Decimal.new("80.0"),
           action_on_exceed: "block",
           is_active: true
         }) do
      {:ok, policy} ->
        policy

      {:error, %Ecto.Changeset{} = changeset} ->
        Repo.rollback({:budget_policy, changeset})
    end
  end

  defp budget_cents_to_usd(cents) when is_integer(cents) and cents > 0 do
    cents
    |> Decimal.new()
    |> Decimal.div(Decimal.new(100))
    |> Decimal.round(2)
  end

  defp create_blueprint_extra_agents!(agent_specs, initial_refs, base_attrs) do
    Enum.reduce(agent_specs, {[], initial_refs}, fn spec, {agents, refs} ->
      parent = Map.get(refs, spec.parent) || refs.ceo

      agent =
        create_template_agent!(%{
          company_id: base_attrs.company_id,
          project_id: base_attrs.project_id,
          parent_id: parent && parent.id,
          created_by_agent_id: parent && parent.id,
          name: spec.name,
          title: spec.title,
          role: spec.role,
          adapter: base_attrs.adapter,
          runtime_config: Map.get(base_attrs, :runtime_config, %{}),
          max_concurrent_jobs: Map.get(spec, :max_concurrent_jobs, 1),
          capabilities: spec.capabilities,
          instructions: spec.instructions
        })

      {agents ++ [agent], Map.put(refs, spec.ref, agent)}
    end)
  end

  defp blueprint_seed_specs(blueprint, agent_refs) do
    blueprint.seed_issues
    |> Enum.with_index(1)
    |> Enum.map(fn {seed, number} ->
      assignee = Map.get(agent_refs, seed.assignee) || agent_refs.ceo
      role = Map.get(seed, :assigned_role) || Atom.to_string(assignee.role)

      seed
      |> Map.put(:number, number)
      |> Map.put(:assignee_id, assignee.id)
      |> Map.put(:assigned_role, role)
    end)
  end

  defp blueprint_key_from_attrs(attrs) do
    attrs[:blueprint] || attrs["blueprint"] || attrs[:blueprint_key] || attrs["blueprint_key"]
  end

  defp find_autonomous_company_blueprint(nil), do: nil

  defp find_autonomous_company_blueprint(key) do
    normalized_key = key |> to_string() |> String.trim()
    Enum.find(@autonomous_company_blueprints, &(&1.key == normalized_key))
  end

  defp public_blueprint(blueprint) do
    launch_manifest = blueprint_launch_manifest(blueprint, 2)

    %{
      key: blueprint.key,
      name: blueprint.name,
      description: blueprint.description,
      default_goal: blueprint.default_goal,
      default_prefix: blueprint.default_prefix,
      project_name: blueprint.project_name,
      role_summary: blueprint.role_summary,
      seed_issue_count: length(blueprint.seed_issues),
      seed_issue_titles: Enum.map(blueprint.seed_issues, & &1.title),
      default_agent_count: launch_manifest["agent_count"],
      extra_agent_count: launch_manifest["extra_agent_count"],
      role_count: launch_manifest["role_count"],
      roles: launch_manifest["roles"],
      capability_count: launch_manifest["capability_count"],
      capability_tags: launch_manifest["capability_tags"],
      launch_manifest: launch_manifest
    }
  end

  defp blueprint_launch_manifest(blueprint, engineer_count) do
    roster = blueprint_agent_roster(blueprint, engineer_count)
    seed_work = Enum.map(blueprint.seed_issues, &blueprint_seed_manifest/1)
    roles = roster |> Enum.map(& &1["role"]) |> Enum.uniq() |> Enum.sort()

    capability_tags =
      roster |> Enum.flat_map(& &1["capability_tags"]) |> Enum.uniq() |> Enum.sort()

    %{
      "blueprint_key" => blueprint.key,
      "blueprint_name" => blueprint.name,
      "default_prefix" => blueprint.default_prefix,
      "default_goal" => blueprint.default_goal,
      "engineer_count" => engineer_count,
      "agent_count" => length(roster),
      "base_agent_count" => 4 + engineer_count,
      "extra_agent_count" => length(blueprint.extra_agents),
      "role_count" => length(roles),
      "roles" => roles,
      "capability_count" => length(capability_tags),
      "capability_tags" => capability_tags,
      "agent_roster" => roster,
      "seed_issue_count" => length(seed_work),
      "seed_issue_titles" => Enum.map(seed_work, & &1["title"]),
      "seed_work" => seed_work
    }
  end

  defp blueprint_agent_roster(blueprint, engineer_count) do
    blueprint_base_agent_roster(engineer_count) ++
      Enum.map(blueprint.extra_agents, &extra_agent_manifest/1)
  end

  defp blueprint_base_agent_roster(engineer_count) do
    [
      %{
        "ref" => "ceo",
        "name" => "CEO",
        "title" => "Chief Executive Officer",
        "role" => "ceo",
        "reports_to" => nil,
        "capability_tags" => ~w(budgeting hiring planning strategy)
      },
      %{
        "ref" => "cto",
        "name" => "CTO",
        "title" => "Chief Technology Officer",
        "role" => "cto",
        "reports_to" => "ceo",
        "capability_tags" => ~w(architecture review technical_planning triage)
      },
      %{
        "ref" => "product_lead",
        "name" => "Product Lead",
        "title" => "Product Lead",
        "role" => "product_manager",
        "reports_to" => "ceo",
        "capability_tags" => ~w(acceptance_criteria prioritization stakeholder_alignment)
      },
      %{
        "ref" => "design_lead",
        "name" => "Design Lead",
        "title" => "Design Lead",
        "role" => "designer",
        "reports_to" => "ceo",
        "capability_tags" => ~w(interaction_design user_flows visual_specs)
      }
    ] ++ engineer_manifests(engineer_count)
  end

  defp engineer_manifests(0), do: []

  defp engineer_manifests(engineer_count) do
    for index <- 1..engineer_count do
      %{
        "ref" => "engineer_#{index}",
        "name" => "Engineer #{index}",
        "title" => "Software Engineer",
        "role" => "engineer",
        "reports_to" => "cto",
        "capability_tags" => ~w(debugging implementation testing)
      }
    end
  end

  defp extra_agent_manifest(spec) do
    %{
      "ref" => Atom.to_string(spec.ref),
      "name" => spec.name,
      "title" => spec.title,
      "role" => Atom.to_string(spec.role),
      "reports_to" => Atom.to_string(spec.parent),
      "capability_tags" => spec.capabilities |> Map.keys() |> Enum.sort()
    }
  end

  defp blueprint_seed_manifest(seed) do
    %{
      "title" => seed.title,
      "priority" => Atom.to_string(seed.priority),
      "assignee_ref" => Atom.to_string(seed.assignee)
    }
  end

  defp normalize_engineer_count(count) when is_integer(count), do: count |> max(0) |> min(8)

  defp normalize_engineer_count(count) when is_binary(count) do
    case Integer.parse(count) do
      {value, _} -> normalize_engineer_count(value)
      :error -> 2
    end
  end

  defp normalize_engineer_count(_count), do: 2

  defp normalize_engineer_names(names) when is_list(names) do
    Enum.map(names, fn
      name when is_binary(name) -> String.trim(name)
      _ -> ""
    end)
  end

  defp normalize_engineer_names(_), do: []

  # Blank/absent project names fall back to the blueprint's default so the
  # launch stays backward compatible for callers that never pass one.
  defp normalize_project_name(name, blueprint) do
    case trim_or_nil(name) do
      nil -> blueprint.project_name
      trimmed -> String.slice(trimmed, 0, 255)
    end
  end

  defp engineer_name(names, index) do
    case Enum.at(names, index - 1) do
      name when is_binary(name) and name != "" -> name
      _ -> "Engineer #{index}"
    end
  end

  # Builds the extra runtime_config merged into every launched agent.
  # command -> top-level "command" (read by adapters via the orchestrator's
  # config merge); model -> "env"."ANTHROPIC_MODEL" (injected by profile_env).
  defp normalize_agent_runtime(%{} = runtime, adapter) do
    command = trim_or_nil(runtime["command"] || runtime[:command])
    model = trim_or_nil(runtime["model"] || runtime[:model])

    %{}
    |> then(fn config -> if command, do: Map.put(config, "command", command), else: config end)
    |> put_runtime_model(model, adapter)
  end

  defp normalize_agent_runtime(_, _adapter), do: %{}

  defp put_runtime_model(config, nil, _adapter), do: config

  # Claude-compatible CLIs read the model from ANTHROPIC_MODEL; every other
  # adapter reads config["model"] (Codex/Cursor pass it as a --model arg).
  defp put_runtime_model(config, model, :claude_code) do
    Map.put(config, "env", %{"ANTHROPIC_MODEL" => model})
  end

  defp put_runtime_model(config, model, _adapter), do: Map.put(config, "model", model)

  # Per-role runtime overrides from onboarding: each role (ceo/cto/engineer)
  # may pick its own adapter + model + command; blank fields fall back to the
  # shared runtime, and a missing role entry falls back entirely.
  defp normalize_role_runtimes(role_runtimes, default_adapter, default_runtime) do
    role_runtimes = if is_map(role_runtimes), do: role_runtimes, else: %{}

    Map.new(["ceo", "cto", "engineer"], fn role ->
      case role_runtimes[role] do
        %{} = runtime ->
          adapter = normalize_adapter(runtime["adapter"] || runtime[:adapter] || default_adapter)

          config =
            case normalize_agent_runtime(runtime, adapter) do
              empty when empty == %{} ->
                if adapter == default_adapter, do: default_runtime, else: %{}

              config ->
                config
            end

          {role, {adapter, config}}

        _ ->
          {role, {default_adapter, default_runtime}}
      end
    end)
  end

  defp trim_or_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trim_or_nil(_), do: nil

  defp create_template_agent!(attrs) do
    role = attrs[:role] || attrs["role"]
    runtime_config = Map.merge(%{"autonomous" => true}, attrs[:runtime_config] || %{})

    attrs =
      attrs
      |> Map.delete(:runtime_config)
      |> Map.update(
        :instructions,
        RolePlaybook.default_overrides_template(role),
        &RolePlaybook.starter_overrides(role, &1)
      )

    %Agent{}
    |> Agent.changeset(
      Map.merge(attrs, %{
        status: :idle,
        context_mode: "company",
        runtime_config: runtime_config
      })
    )
    |> Repo.insert!()
  end

  defp normalize_adapter(adapter) when is_atom(adapter), do: adapter

  defp normalize_adapter(adapter) when is_binary(adapter) do
    try do
      String.to_existing_atom(adapter)
    rescue
      ArgumentError -> :claude_code
    end
  end

  defp unique_slug(name) do
    base =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> case do
        "" -> "company"
        slug -> slug
      end
      |> String.slice(0, 42)

    unique_slug(base, 0)
  end

  defp unique_slug(base, 0) do
    if get_company_by_slug(base), do: unique_slug(base, 1), else: base
  end

  defp unique_slug(base, suffix) do
    candidate = "#{base}-#{suffix}"
    if get_company_by_slug(candidate), do: unique_slug(base, suffix + 1), else: candidate
  end

  defp unique_project_prefix(prefix) do
    base =
      prefix
      |> to_string()
      |> String.upcase()
      |> String.replace(~r/[^A-Z0-9]+/, "")
      |> case do
        "" -> "LLM"
        value -> String.slice(value, 0, 7)
      end

    unique_project_prefix(base, 0)
  end

  defp unique_project_prefix(base, 0) do
    if Repo.get_by(Project, prefix: base), do: unique_project_prefix(base, 1), else: base
  end

  defp unique_project_prefix(base, suffix) do
    suffix_text = alphabetic_suffix(suffix)
    base_length = max(0, 10 - String.length(suffix_text))

    candidate =
      base
      |> String.slice(0, base_length)
      |> Kernel.<>(suffix_text)

    if Repo.get_by(Project, prefix: candidate),
      do: unique_project_prefix(base, suffix + 1),
      else: candidate
  end

  defp alphabetic_suffix(number) when number > 0 do
    number
    |> alphabetic_suffix([])
    |> Enum.join()
  end

  defp alphabetic_suffix(0, acc), do: acc

  defp alphabetic_suffix(number, acc) do
    remainder = rem(number - 1, 26)
    letter = <<?A + remainder>>
    alphabetic_suffix(div(number - 1, 26), [letter | acc])
  end

  # ── Multi-tenancy scoping ──

  def scope_query(queryable, company_id) do
    from(q in queryable, where: q.company_id == ^company_id)
  end

  def list_company_projects(company_id) do
    from(p in Cympho.Projects.Project, where: p.company_id == ^company_id)
    |> Repo.all()
  end

  def list_company_agents(company_id) do
    Cympho.Agents.list_agents_by_company(company_id)
  end

  def list_company_issues(company_id) do
    from(i in Cympho.Issues.Issue, where: i.company_id == ^company_id)
    |> Repo.all()
  end

  def list_company_goals(company_id) do
    from(g in Cympho.Goals.Goal, where: g.company_id == ^company_id)
    |> Repo.all()
  end

  def list_company_labels(company_id) do
    from(l in Cympho.Labels.Label, where: l.company_id == ^company_id)
    |> Repo.all()
  end

  # ── Memberships ──

  def list_memberships(company_id) do
    from(m in CompanyMembership, where: m.company_id == ^company_id, preload: [:user])
    |> Repo.all()
  end

  def list_memberships_for_user(user_id) do
    from(m in CompanyMembership,
      where: m.user_id == ^user_id,
      order_by: [asc: m.inserted_at, asc: m.id],
      preload: [:company]
    )
    |> Repo.all()
  end

  def get_membership(user_id, company_id) do
    Repo.get_by(CompanyMembership, user_id: user_id, company_id: company_id)
  end

  def create_membership(attrs \\ %{}) do
    %CompanyMembership{}
    |> CompanyMembership.changeset(attrs)
    |> Repo.insert()
  end

  def update_membership(%CompanyMembership{} = membership, attrs) do
    membership
    |> CompanyMembership.changeset(attrs)
    |> Repo.update()
  end

  def delete_membership(%CompanyMembership{} = membership) do
    Repo.delete(membership)
  end

  @doc """
  Ensures the user is an owner and board member of the company.

  `UserAuth` resolves `current_company` only from memberships, not from
  `users.company_id` alone. Install seed and dev-session bootstrap use this
  so the admin/owner is not bounced to `/onboarding` after login.
  """
  def ensure_owner_membership!(user_id, company_id)
      when is_binary(user_id) and is_binary(company_id) do
    case get_membership(user_id, company_id) do
      nil ->
        create_membership!(%{
          user_id: user_id,
          company_id: company_id,
          role: "owner",
          is_board_member: true
        })

      %CompanyMembership{} = membership ->
        case update_membership(membership, %{role: "owner", is_board_member: true}) do
          {:ok, membership} ->
            membership

          {:error, changeset} ->
            raise Ecto.InvalidChangesetError, action: :update, changeset: changeset
        end
    end
  end

  def has_access?(user_id, company_id) do
    case get_membership(user_id, company_id) do
      nil -> false
      _membership -> true
    end
  end

  def get_role(user_id, company_id) do
    case get_membership(user_id, company_id) do
      nil -> nil
      membership -> membership.role
    end
  end

  def admin?(user_id, company_id) do
    role = get_role(user_id, company_id)
    role in ["owner", "admin"]
  end

  @doc """
  Returns true if the user is a board member of the given company.
  """
  def is_board_member?(user_id, company_id) do
    case get_membership(user_id, company_id) do
      nil -> false
      membership -> membership.is_board_member == true
    end
  end

  @doc """
  Lists all board members for a company.
  """
  def list_board_members(company_id) do
    from(m in CompanyMembership,
      where: m.company_id == ^company_id and m.is_board_member == true,
      preload: [:user]
    )
    |> Repo.all()
  end

  @doc """
  Updates a board membership (e.g., toggling board member status).
  """
  def update_board_membership(%CompanyMembership{} = membership, attrs) do
    membership
    |> CompanyMembership.changeset(attrs)
    |> Repo.update()
  end

  # ── Invites ──

  def create_invite(attrs) do
    token = CompanyInvite.generate_token()
    expires_at = DateTime.add(DateTime.utc_now(), 7 * 24 * 3600, :second)

    %CompanyInvite{}
    |> CompanyInvite.changeset(Map.merge(attrs, %{"token" => token, "expires_at" => expires_at}))
    |> Repo.insert()
  end

  def get_invite_by_token(token) do
    Repo.get_by(CompanyInvite, token: token)
  end

  def list_pending_invites(company_id) do
    from(i in CompanyInvite,
      where: i.company_id == ^company_id and i.status == "pending",
      order_by: [desc: i.inserted_at]
    )
    |> Repo.all()
  end

  def accept_invite(token, user_id) do
    invite = get_invite_by_token(token)
    user = user_id && Cympho.Users.get_user!(user_id)

    cond do
      is_nil(invite) ->
        {:error, :not_found}

      CompanyInvite.expired?(invite) ->
        mark_invite_expired(invite)
        {:error, :expired}

      invite.status != "pending" ->
        {:error, :already_used}

      invite_email_mismatch?(invite, user) ->
        {:error, :email_mismatch}

      true ->
        Repo.transaction(fn ->
          create_membership!(%{
            user_id: user_id,
            company_id: invite.company_id,
            role: invite.role
          })

          invite
          |> CompanyInvite.changeset(%{status: "accepted"})
          |> Repo.update!()
        end)
    end
  end

  # An invite that names a recipient email may be accepted only by the user
  # with that email. Invites without an email (open links) stay unrestricted.
  defp invite_email_mismatch?(%{email: invite_email}, %{email: user_email})
       when is_binary(invite_email) and is_binary(user_email) do
    String.downcase(invite_email) != String.downcase(user_email)
  end

  defp invite_email_mismatch?(_invite, _user), do: false

  def create_membership!(attrs) do
    %CompanyMembership{}
    |> CompanyMembership.changeset(attrs)
    |> Repo.insert!()
  end

  def revoke_invite(%CompanyInvite{} = invite) do
    invite
    |> CompanyInvite.changeset(%{status: "revoked"})
    |> Repo.update()
  end

  defp mark_invite_expired(invite) do
    invite
    |> CompanyInvite.changeset(%{status: "expired"})
    |> Repo.update()
  end

  def expire_stale_invites do
    from(i in CompanyInvite,
      where: i.status == "pending" and i.expires_at < ^DateTime.utc_now()
    )
    |> Repo.update_all(set: [status: "expired"])
  end

  # ── Join Requests ──

  def create_join_request(attrs) do
    %JoinRequest{}
    |> JoinRequest.changeset(attrs)
    |> Repo.insert()
  end

  def list_pending_join_requests(company_id) do
    from(j in JoinRequest,
      where: j.company_id == ^company_id and j.status == "pending",
      preload: [:user],
      order_by: [desc: j.inserted_at]
    )
    |> Repo.all()
  end

  def approve_join_request(%JoinRequest{} = request, reviewer_id) do
    Repo.transaction(fn ->
      request
      |> JoinRequest.changeset(%{
        status: "approved",
        reviewed_by_id: reviewer_id,
        reviewed_at: DateTime.utc_now()
      })
      |> Repo.update!()

      create_membership!(%{
        user_id: request.user_id,
        company_id: request.company_id,
        role: "member"
      })
    end)
  end

  def reject_join_request(%JoinRequest{} = request, reviewer_id) do
    request
    |> JoinRequest.changeset(%{
      status: "rejected",
      reviewed_by_id: reviewer_id,
      reviewed_at: DateTime.utc_now()
    })
    |> Repo.update()
  end

  # ── Export ──

  @secret_fields ~w(
    password_hash
    key_hash
    encrypted_value
    webhook_secret
    github_webhook_secret
    api_key
    password
    secret
    token
    authorization
    cookie
    database_url
    key
    credential
    credentials
    headers
    env
    auth
    authentication
    secrets
  )
  @secret_field_suffixes ~w(
    _api_key
    _password
    _secret
    _token
    _authorization
    _cookie
    _database_url
    _key
    _credential
    _credentials
  )
  @redacted_secret_marker "***REDACTED***"

  def export_company(company_id) do
    company = get_company!(company_id)

    %{
      company: scrub(company),
      users: export_users(company_id),
      memberships: export_memberships(company_id),
      projects: export_projects(company_id),
      agents: export_agents(company_id),
      issues: export_issues(company_id),
      goals: export_goals(company_id),
      labels: export_labels(company_id),
      secret_manifest: export_secret_manifest(company_id),
      exported_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      version: 1
    }
  end

  @doc """
  Returns non-sensitive secret metadata for company portability exports.

  Secret values, encrypted payloads, and hashes are intentionally omitted. The
  manifest is a restore checklist for operators after importing a company.
  """
  def export_secret_manifest(company_id) do
    Secret
    |> where(company_id: ^company_id)
    |> where(is_active: true)
    |> order_by([s], asc: s.scope, asc: s.key, asc: s.id)
    |> Repo.all()
    |> Enum.map(fn secret ->
      %{
        key: secret.key,
        scope: secret.scope,
        scope_id: secret.scope_id,
        description: secret.description,
        version: secret.version,
        inserted_at: secret.inserted_at,
        updated_at: secret.updated_at
      }
    end)
  end

  defp export_users(company_id) do
    from(m in CompanyMembership,
      where: m.company_id == ^company_id,
      preload: [:user]
    )
    |> Repo.all()
    |> Enum.map(fn m -> scrub(Map.from_struct(m.user)) end)
  end

  defp export_memberships(company_id) do
    from(m in CompanyMembership, where: m.company_id == ^company_id)
    |> Repo.all()
    |> Enum.map(&scrub/1)
  end

  defp export_projects(company_id) do
    list_company_projects(company_id)
    |> Enum.map(&scrub/1)
  end

  defp export_agents(company_id) do
    list_company_agents(company_id)
    |> Enum.map(&scrub/1)
  end

  defp export_issues(company_id) do
    from(i in Cympho.Issues.Issue,
      where: i.company_id == ^company_id,
      preload: [:labels, :comments, documents: [:revisions]]
    )
    |> Repo.all()
    |> Enum.map(&scrub_issue/1)
  end

  defp export_goals(company_id) do
    list_company_goals(company_id)
    |> Enum.map(&scrub/1)
  end

  defp export_labels(company_id) do
    list_company_labels(company_id)
    |> Enum.map(&scrub/1)
  end

  defp scrub_issue(issue) do
    issue
    |> scrub()
    |> Map.put(:comments, Enum.map(issue.comments, &scrub_comment/1))
    |> Map.put(:labels, Enum.map(issue.labels, &scrub/1))
  end

  defp scrub_comment(comment) do
    comment
    |> scrub()
    |> Map.delete(:author_agent)
    |> Map.delete(:author_user)
  end

  defp scrub(%DateTime{} = value), do: value
  defp scrub(%NaiveDateTime{} = value), do: value
  defp scrub(%Date{} = value), do: value
  defp scrub(%Time{} = value), do: value

  defp scrub(record) when is_struct(record) do
    record
    |> Map.from_struct()
    |> Map.drop([:__meta__, :__struct__])
    |> scrub_map()
  end

  defp scrub(map) when is_map(map) do
    scrub_map(map)
  end

  defp scrub_map(map) do
    Map.new(map, fn
      {k, v} ->
        if secret_field?(k), do: {k, @redacted_secret_marker}, else: scrub_map_entry(k, v)
    end)
  end

  defp secret_field?(key) do
    key = normalize_secret_field(key)

    key in @secret_fields or
      Enum.any?(@secret_field_suffixes, &String.ends_with?(key, &1))
  end

  defp normalize_secret_field(key) do
    key
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "_")
    |> String.trim("_")
  end

  defp scrub_map_entry(k, v), do: {k, scrub_nested(v)}

  defp scrub_nested(value) when is_map(value), do: scrub(value)
  defp scrub_nested(value) when is_list(value), do: Enum.map(value, &scrub_nested/1)
  defp scrub_nested(value), do: value

  # ── Import ──

  def preview_import(data, opts \\ []), do: Portability.preview_import(data, opts)

  def import_company(data, opts \\ []) do
    slug_strategy = Keyword.get(opts, :slug_strategy, :suffix)

    with {:ok, preview} <- Portability.preview_import(data, slug_strategy: slug_strategy),
         :ok <- import_preview_ready(preview) do
      import_company!(data, slug_strategy, preview.target.slug)
    else
      {:error, %{errors: errors}} when is_list(errors) ->
        {:error, Enum.map_join(errors, " ", & &1.message)}

      error ->
        error
    end
  end

  defp import_preview_ready(%{ready?: true}), do: :ok

  defp import_preview_ready(%{target: %{requested_slug: slug}}) do
    {:error, "Company slug #{slug} already exists and the fail strategy blocks import."}
  end

  defp import_company!(data, slug_strategy, target_slug) when is_map(data) do
    company_data = get_export_field(data, :company, %{})

    Repo.transaction(fn ->
      # Create company with retry loop for slug collision (handles race condition)
      company =
        company_data
        |> create_company_with_retry(slug_strategy, target_slug)
        |> import_record!("Company")

      # Import users first (memberships reference them)
      user_id_map = import_users(get_export_field(data, :users, []), company.id)

      # Import memberships
      import_memberships(get_export_field(data, :memberships, []), company.id, user_id_map)

      # Import labels (issues reference them)
      label_id_map = import_labels(get_export_field(data, :labels, []), company.id)

      # Import projects
      project_id_map = import_projects(get_export_field(data, :projects, []), company.id)

      # Import goals
      goal_id_map =
        import_goals(get_export_field(data, :goals, []), company.id, project_id_map)

      # Import agents
      agent_id_map =
        import_agents(
          get_export_field(data, :agents, []),
          company.id,
          project_id_map
        )

      # Import issues
      issue_id_map =
        import_issues(
          get_export_field(data, :issues, []),
          company.id,
          project_id_map,
          agent_id_map,
          label_id_map,
          goal_id_map,
          user_id_map
        )

      id_maps = %{
        projects: project_id_map,
        agents: agent_id_map,
        issues: issue_id_map,
        goals: goal_id_map,
        labels: label_id_map,
        users: user_id_map
      }

      %{
        company: company,
        id_maps: id_maps,
        secrets_to_restore: secrets_to_restore(data, id_maps)
      }
    end)
  end

  defp secrets_to_restore(data, id_maps) do
    data
    |> get_export_field(:secret_manifest, [])
    |> Enum.map(&secret_restore_entry(&1, id_maps))
  end

  defp secret_restore_entry(entry, id_maps) do
    scope = get_export_field(entry, :scope)
    original_scope_id = get_export_field(entry, :scope_id)
    scope_id = remap_secret_scope_id(scope, original_scope_id, id_maps)

    %{
      key: get_export_field(entry, :key),
      scope: scope,
      scope_id: scope_id,
      original_scope_id: original_scope_id,
      description: get_export_field(entry, :description),
      version: get_export_field(entry, :version),
      restore_status: secret_restore_status(scope, original_scope_id, scope_id)
    }
  end

  defp remap_secret_scope_id(scope, scope_id, %{projects: project_id_map})
       when scope in ["project", :project] and is_binary(scope_id),
       do: remap_id!(project_id_map, scope_id, "secret project scope")

  defp remap_secret_scope_id(scope, scope_id, %{agents: agent_id_map})
       when scope in ["agent", :agent] and is_binary(scope_id),
       do: remap_id!(agent_id_map, scope_id, "secret agent scope")

  defp remap_secret_scope_id(_scope, scope_id, _id_maps), do: scope_id

  defp secret_restore_status(scope, original_scope_id, nil)
       when scope in ["project", :project, "agent", :agent] and is_binary(original_scope_id),
       do: "missing_scope_target"

  defp secret_restore_status(_scope, _original_scope_id, _scope_id), do: "requires_value"

  defp get_export_field(map, key, default \\ nil)

  defp get_export_field(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp get_export_field(_map, _key, default), do: default

  # Creates a company, retrying with a new slug suffix on unique constraint violation
  defp create_company_with_retry(company_data, slug_strategy, target_slug, attempts \\ 1) do
    original_slug = get_export_field(company_data, :slug, "imported-company")

    slug = if attempts == 1, do: target_slug, else: retry_company_slug(original_slug, attempts)

    attrs = %{
      name: get_export_field(company_data, :name),
      slug: slug,
      logo_url: get_export_field(company_data, :logo_url)
    }

    case Repo.insert(Company.changeset(%Company{}, attrs), mode: :savepoint) do
      {:ok, _company} = result ->
        result

      {:error, %{errors: errors}} = error when is_list(errors) ->
        slug_error = Enum.find(errors, fn {field, _} -> field == :slug end)

        if slug_error && slug_strategy == :suffix && attempts < 10 do
          create_company_with_retry(company_data, slug_strategy, target_slug, attempts + 1)
        else
          error
        end

      {:error, _} = error ->
        error
    end
  end

  defp retry_company_slug(original_slug, attempts) do
    suffix = "-copy-#{attempts}"
    String.slice(original_slug, 0, 50 - String.length(suffix)) <> suffix
  end

  # Returns map of old_user_id -> new_user_id
  defp import_users(users, company_id) do
    Enum.reduce(users, %{}, fn user_data, acc ->
      source_id = source_id!(user_data, "user")

      # Check if user with this email already exists
      existing_user = Repo.get_by(Cympho.Users.User, email: get_export_field(user_data, :email))

      if existing_user do
        # Link to existing user - the membership will use the existing user
        Map.put(acc, source_id, existing_user.id)
      else
        # Create new user with a random password they must reset
        random_password = :crypto.strong_rand_bytes(16) |> Base.encode64()

        attrs = %{
          email: get_export_field(user_data, :email),
          name: get_export_field(user_data, :name),
          password: random_password,
          company_id: company_id
        }

        user =
          %Cympho.Users.User{}
          |> Cympho.Users.User.registration_changeset(attrs)
          |> Repo.insert()
          |> import_record!("User")

        Map.put(acc, source_id, user.id)
      end
    end)
  end

  defp import_memberships(memberships, company_id, user_id_map) do
    Enum.each(memberships, fn membership_data ->
      new_user_id =
        remap_id!(
          user_id_map,
          get_export_field(membership_data, :user_id),
          "membership user"
        )

      attrs = %{
        user_id: new_user_id,
        company_id: company_id,
        role: get_export_field(membership_data, :role, "member"),
        is_board_member: get_export_field(membership_data, :is_board_member, false)
      }

      %CompanyMembership{}
      |> CompanyMembership.changeset(attrs)
      |> Repo.insert()
      |> import_record!("Membership")
    end)
  end

  defp import_labels(labels, company_id) do
    Enum.reduce(labels, %{}, fn label_data, acc ->
      label =
        label_data
        |> create_label_with_retry(company_id)
        |> import_record!("Label")

      Map.put(acc, source_id!(label_data, "label"), label.id)
    end)
  end

  defp create_label_with_retry(label_data, company_id, attempts \\ 1) do
    original_name = get_export_field(label_data, :name)

    attrs = %{
      name: import_label_name(original_name, attempts),
      color: get_export_field(label_data, :color, "#6B7280"),
      description: get_export_field(label_data, :description),
      company_id: company_id
    }

    case Repo.insert(
           %Cympho.Labels.Label{} |> Cympho.Labels.Label.changeset(attrs),
           mode: :savepoint
         ) do
      {:ok, _label} = result ->
        result

      {:error, %Ecto.Changeset{} = changeset} = error ->
        if unique_constraint_error?(changeset, :name) and attempts < 100 do
          create_label_with_retry(label_data, company_id, attempts + 1)
        else
          error
        end
    end
  end

  defp import_label_name(name, 1), do: name

  defp import_label_name(name, attempts) do
    suffix = if attempts == 2, do: "-copy", else: "-copy-#{attempts - 1}"
    String.slice(to_string(name), 0, 50 - String.length(suffix)) <> suffix
  end

  defp unique_constraint_error?(changeset, field) do
    changeset.errors
    |> Keyword.get_values(field)
    |> Enum.any?(fn {_message, opts} -> opts[:constraint] == :unique end)
  end

  defp import_projects(projects, company_id) do
    Enum.reduce(projects, %{}, fn project_data, acc ->
      project =
        project_data
        |> create_project_with_retry(company_id)
        |> import_record!("Project")

      Map.put(acc, source_id!(project_data, "project"), project.id)
    end)
  end

  defp create_project_with_retry(project_data, company_id, attempts \\ 1) do
    prefix = import_project_prefix(get_export_field(project_data, :prefix), attempts)

    attrs = %{
      name: get_export_field(project_data, :name),
      description: get_export_field(project_data, :description),
      prefix: prefix,
      settings: get_export_field(project_data, :settings, %{}),
      company_id: company_id
    }

    case Repo.insert(
           %Cympho.Projects.Project{} |> Cympho.Projects.Project.changeset(attrs),
           mode: :savepoint
         ) do
      {:ok, _project} = result ->
        result

      {:error, %{errors: errors}} = error when is_list(errors) ->
        prefix_error = Enum.find(errors, fn {field, _} -> field == :prefix end)

        if prefix_error && attempts < 10 do
          create_project_with_retry(project_data, company_id, attempts + 1)
        else
          error
        end

      {:error, _} = error ->
        error
    end
  end

  defp import_project_prefix(prefix, attempts) do
    suffix = alpha_suffix(attempts)

    base =
      prefix
      |> to_string()
      |> String.upcase()
      |> String.replace(~r/[^A-Z]+/, "")
      |> case do
        "" -> "PRJ"
        value -> value
      end

    base_length = max(2, 10 - String.length(suffix))
    String.slice(base, 0, base_length) <> suffix
  end

  defp alpha_suffix(number) when number > 0 do
    number
    |> Stream.unfold(fn
      0 ->
        nil

      n ->
        index = rem(n - 1, 26)
        next = div(n - 1, 26)
        {<<?A + index>>, next}
    end)
    |> Enum.reverse()
    |> Enum.join()
  end

  defp import_goals(goals, company_id, project_id_map) do
    goal_id_map =
      Enum.reduce(goals, %{}, fn goal_data, acc ->
        attrs = %{
          title: get_export_field(goal_data, :title),
          description: get_export_field(goal_data, :description),
          status: get_export_field(goal_data, :status, "active"),
          priority: get_export_field(goal_data, :priority, "medium"),
          goal_type: get_export_field(goal_data, :goal_type, :initiative),
          target_date: get_export_field(goal_data, :target_date),
          project_id:
            remap_optional_id!(
              project_id_map,
              get_export_field(goal_data, :project_id),
              "goal project"
            ),
          company_id: company_id
        }

        goal =
          %Cympho.Goals.Goal{}
          |> Cympho.Goals.Goal.changeset(attrs)
          |> Repo.insert()
          |> import_record!("Goal")

        Map.put(acc, source_id!(goal_data, "goal"), goal.id)
      end)

    Enum.each(goals, fn goal_data ->
      old_parent_id = get_export_field(goal_data, :parent_id)

      if old_parent_id do
        goal =
          Repo.get!(
            Cympho.Goals.Goal,
            remap_id!(goal_id_map, source_id!(goal_data, "goal"), "goal")
          )

        attrs = %{
          parent_id: remap_id!(goal_id_map, old_parent_id, "goal parent"),
          goal_type: get_export_field(goal_data, :goal_type, :initiative)
        }

        goal
        |> Cympho.Goals.Goal.changeset(attrs)
        |> Repo.update()
        |> import_record!("Goal parent")
      end
    end)

    goal_id_map
  end

  defp import_agents(agents, company_id, project_id_map) do
    agent_id_map =
      Enum.reduce(agents, %{}, fn agent_data, acc ->
        agent =
          agent_data
          |> create_agent_with_retry(company_id, project_id_map)
          |> import_record!("Agent")

        Map.put(acc, source_id!(agent_data, "agent"), agent.id)
      end)

    Enum.each(agents, fn agent_data ->
      attrs = %{
        parent_id:
          remap_optional_id!(
            agent_id_map,
            get_export_field(agent_data, :parent_id),
            "agent parent"
          ),
        created_by_agent_id:
          remap_optional_id!(
            agent_id_map,
            get_export_field(agent_data, :created_by_agent_id),
            "agent creator"
          )
      }

      if Enum.any?(attrs, fn {_key, value} -> not is_nil(value) end) do
        Cympho.Agents.Agent
        |> Repo.get!(remap_id!(agent_id_map, source_id!(agent_data, "agent"), "agent"))
        |> Cympho.Agents.Agent.changeset(attrs)
        |> Repo.update()
        |> import_record!("Agent hierarchy")
      end
    end)

    agent_id_map
  end

  defp create_agent_with_retry(agent_data, company_id, project_id_map, attempts \\ 1) do
    original_url_key = get_export_field(agent_data, :url_key)

    url_key =
      case original_url_key do
        nil -> nil
        _ -> "#{original_url_key}-#{:rand.uniform(9999)}"
      end

    runtime_config =
      agent_data
      |> get_export_field(:runtime_config, %{})
      |> import_scrubbed_map()

    heartbeat_config =
      agent_data
      |> get_export_field(:heartbeat_config, %{})
      |> import_scrubbed_map()
      |> disable_imported_heartbeat()

    attrs = %{
      name: get_export_field(agent_data, :name),
      url_key: url_key,
      title: get_export_field(agent_data, :title),
      role: get_export_field(agent_data, :role, :engineer),
      adapter: get_export_field(agent_data, :adapter),
      config:
        agent_data
        |> get_export_field(:config, %{})
        |> import_scrubbed_map(),
      runtime_config: runtime_config,
      heartbeat_config: heartbeat_config,
      capabilities:
        agent_data
        |> get_export_field(:capabilities, %{})
        |> import_scrubbed_map(),
      permissions:
        agent_data
        |> get_export_field(:permissions, %{})
        |> import_scrubbed_map(),
      budget:
        agent_data
        |> get_export_field(:budget, %{})
        |> import_scrubbed_map(),
      icon: get_export_field(agent_data, :icon),
      instructions: get_export_field(agent_data, :instructions),
      instructions_path: get_export_field(agent_data, :instructions_path),
      context_mode: get_export_field(agent_data, :context_mode, "company"),
      max_concurrent_jobs: get_export_field(agent_data, :max_concurrent_jobs, 3),
      budget_monthly_cents: get_export_field(agent_data, :budget_monthly_cents, 0),
      # Imported agents must not auto-wake: timers off until an operator resumes.
      status: :paused,
      pause_reason: "Imported via company portability; heartbeat timers disabled.",
      paused_at: DateTime.utc_now() |> DateTime.truncate(:second),
      project_id:
        remap_optional_id!(
          project_id_map,
          get_export_field(agent_data, :project_id),
          "agent project"
        ),
      company_id: company_id
    }

    case Repo.insert(
           %Cympho.Agents.Agent{} |> Cympho.Agents.Agent.changeset(attrs),
           mode: :savepoint
         ) do
      {:ok, _agent} = result ->
        result

      {:error, %{errors: errors}} = error when is_list(errors) ->
        url_key_error = Enum.find(errors, fn {field, _} -> field == :url_key end)

        if url_key_error && attempts < 10 do
          create_agent_with_retry(agent_data, company_id, project_id_map, attempts + 1)
        else
          error
        end

      {:error, _} = error ->
        error
    end
  end

  defp import_scrubbed_map(value) when is_map(value),
    do: drop_redacted_secret_placeholders(value)

  defp import_scrubbed_map(_value), do: %{}

  # Heartbeat timers stay off after import so restored adapters do not wake on
  # the destination instance until secrets/runtime are revalidated.
  defp disable_imported_heartbeat(config) when is_map(config) do
    config
    |> Map.put("enabled", false)
    |> Map.delete(:enabled)
  end

  defp disable_imported_heartbeat(_config), do: %{"enabled" => false}

  defp drop_redacted_secret_placeholders(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested_value}, acc ->
      if nested_value == @redacted_secret_marker do
        acc
      else
        Map.put(acc, key, drop_redacted_secret_placeholders(nested_value))
      end
    end)
  end

  defp drop_redacted_secret_placeholders(value) when is_list(value) do
    value
    |> Enum.reject(&(&1 == @redacted_secret_marker))
    |> Enum.map(&drop_redacted_secret_placeholders/1)
  end

  defp drop_redacted_secret_placeholders(value), do: value

  defp import_issues(
         issues,
         company_id,
         project_id_map,
         agent_id_map,
         label_id_map,
         goal_id_map,
         user_id_map
       ) do
    issue_id_map =
      Enum.reduce(issues, %{}, fn issue_data, acc ->
        attrs = %{
          title: get_export_field(issue_data, :title),
          description: get_export_field(issue_data, :description),
          status: get_export_field(issue_data, :status, :backlog),
          priority: get_export_field(issue_data, :priority, :medium),
          work_mode: get_export_field(issue_data, :work_mode, :standard),
          project_id:
            remap_optional_id!(
              project_id_map,
              get_export_field(issue_data, :project_id),
              "issue project"
            ),
          assignee_id:
            remap_optional_id!(
              agent_id_map,
              get_export_field(issue_data, :assignee_id),
              "issue assignee"
            ),
          assignee_user_id:
            remap_optional_id!(
              user_id_map,
              get_export_field(issue_data, :assignee_user_id),
              "issue user assignee"
            ),
          goal_id:
            remap_optional_id!(
              goal_id_map,
              get_export_field(issue_data, :goal_id),
              "issue goal"
            ),
          created_by_agent_id:
            remap_optional_id!(
              agent_id_map,
              get_export_field(issue_data, :created_by_agent_id),
              "issue agent creator"
            ),
          created_by_user_id:
            remap_optional_id!(
              user_id_map,
              get_export_field(issue_data, :created_by_user_id),
              "issue user creator"
            ),
          last_reviewer_id:
            remap_optional_id!(
              agent_id_map,
              get_export_field(issue_data, :last_reviewer_id),
              "issue last reviewer"
            ),
          company_id: company_id
        }

        issue =
          %Cympho.Issues.Issue{}
          |> Cympho.Issues.Issue.changeset(attrs)
          |> Repo.insert()
          |> import_record!("Issue")

        import_issue_labels!(issue, issue_data, company_id, label_id_map)
        import_issue_comments!(issue, issue_data, agent_id_map, user_id_map)

        Map.put(acc, source_id!(issue_data, "issue"), issue.id)
      end)

    Enum.each(issues, fn issue_data ->
      old_parent_id = get_export_field(issue_data, :parent_id)

      if old_parent_id do
        Cympho.Issues.Issue
        |> Repo.get!(remap_id!(issue_id_map, source_id!(issue_data, "issue"), "issue"))
        |> Cympho.Issues.Issue.changeset(%{
          parent_id: remap_id!(issue_id_map, old_parent_id, "issue parent")
        })
        |> Repo.update()
        |> import_record!("Issue parent")
      end
    end)

    issue_id_map
  end

  defp import_issue_labels!(issue, issue_data, company_id, label_id_map) do
    label_ids =
      issue_data
      |> get_export_field(:labels, [])
      |> Enum.map(fn label ->
        remap_id!(label_id_map, get_export_field(label, :id), "issue label")
      end)

    if label_ids != [] do
      labels =
        Repo.all(
          from label in Cympho.Labels.Label,
            where: label.company_id == ^company_id and label.id in ^label_ids
        )

      if length(labels) != length(label_ids) do
        Repo.rollback("Issue label import failed: a label did not belong to the imported company")
      end

      issue
      |> Repo.preload(:labels)
      |> Cympho.Issues.Issue.changeset(%{})
      |> Ecto.Changeset.put_assoc(:labels, labels)
      |> Repo.update()
      |> import_record!("Issue label")
    end
  end

  defp import_issue_comments!(issue, issue_data, agent_id_map, user_id_map) do
    issue_data
    |> get_export_field(:comments, [])
    |> Enum.each(fn comment_data ->
      {author_type, author_id} =
        import_comment_author!(comment_data, agent_id_map, user_id_map)

      %Cympho.Comments.Comment{}
      |> Cympho.Comments.Comment.changeset(%{
        issue_id: issue.id,
        body: get_export_field(comment_data, :body, ""),
        author_type: author_type,
        author_id: author_id
      })
      |> Repo.insert()
      |> import_record!("Comment")
    end)
  end

  defp import_comment_author!(comment_data, agent_id_map, user_id_map) do
    author_id = get_export_field(comment_data, :author_id)

    case get_export_field(comment_data, :author_type) do
      author_type when author_type in ["agent", :agent] ->
        {"agent", remap_id!(agent_id_map, author_id, "comment agent author")}

      author_type when author_type in ["user", :user] ->
        {"user", remap_id!(user_id_map, author_id, "comment user author")}

      author_type when author_type in ["system", :system] ->
        {"system", author_id}

      nil ->
        {"system", author_id}

      other ->
        {to_string(other), author_id}
    end
  end

  defp source_id!(data, type) do
    case get_export_field(data, :id) do
      id when is_binary(id) and id != "" -> id
      _id -> Repo.rollback("#{String.capitalize(type)} import failed: missing source ID")
    end
  end

  defp remap_optional_id!(_map, nil, _association), do: nil
  defp remap_optional_id!(map, old_id, association), do: remap_id!(map, old_id, association)

  defp remap_id!(map, old_id, association) do
    case Map.fetch(map, old_id) do
      {:ok, new_id} ->
        new_id

      :error ->
        Repo.rollback(
          "Import failed: #{association} must reference a record included in the import package"
        )
    end
  end

  defp import_record!({:ok, record}, _type), do: record

  defp import_record!({:error, %Ecto.Changeset{} = changeset}, type) do
    Repo.rollback("#{type} import failed: #{inspect(changeset.errors)}")
  end

  defp import_record!({:error, reason}, type) do
    Repo.rollback("#{type} import failed: #{inspect(reason)}")
  end
end
