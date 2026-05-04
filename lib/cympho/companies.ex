defmodule Cympho.Companies do
  import Ecto.Query, warn: false
  alias Cympho.Repo
  alias Cympho.Companies.Company
  alias Cympho.Companies.CompanyMembership
  alias Cympho.Companies.CompanyInvite
  alias Cympho.Companies.JoinRequest
  alias Cympho.Agents.Agent
  alias Cympho.BoardApprovals
  alias Cympho.GovernanceAuditLogs
  alias Cympho.Goals.Goal
  alias Cympho.Issues.Issue
  alias Cympho.Projects.Project

  # ── Company CRUD ──

  def list_companies do
    Company
    |> order_by([c], asc: c.inserted_at, asc: c.name)
    |> Repo.all()
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
    do_update_company(company, attrs)
  end

  def pause_company(%Company{} = company, reason \\ "Paused from dashboard") do
    case execute_company_update(company, %{
           status: "paused",
           paused_at: DateTime.utc_now() |> DateTime.truncate(:second),
           paused_reason: reason
         }) do
      {:ok, updated} = result ->
        Phoenix.PubSub.broadcast(
          Cympho.PubSub,
          "company:#{updated.id}:company",
          {:company_paused, updated}
        )

        result

      error ->
        error
    end
  end

  def resume_company(%Company{} = company) do
    case execute_company_update(company, %{
           status: "active",
           paused_at: nil,
           paused_reason: nil
         }) do
      {:ok, updated} = result ->
        Phoenix.PubSub.broadcast(
          Cympho.PubSub,
          "company:#{updated.id}:company",
          {:company_resumed, updated}
        )

        result

      error ->
        error
    end
  end

  def active?(%Company{status: "active"}), do: true
  def active?(_company), do: false

  defp do_update_company(%Company{} = company, attrs) do
    company
    |> Company.changeset(attrs)
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

        Phoenix.PubSub.broadcast(
          Cympho.PubSub,
          "company:#{updated.id}:company",
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
    Repo.delete(company)
  end

  def change_company(%Company{} = company, attrs \\ %{}) do
    Company.changeset(company, attrs)
  end

  @doc """
  Creates a Paperclip-style autonomous starter company.

  The template creates a company, one project, one top-level company goal, a CEO,
  CTO, and engineers reporting through the CTO, then queues the CEO's first
  strategy issue. It is intentionally local-trusted: no user account is required.
  """
  def create_autonomous_company(attrs \\ %{}) do
    name = attrs[:name] || attrs["name"] || "Autonomous Software Company"

    goal_title =
      attrs[:goal_title] || attrs["goal_title"] || "Build and run the business autonomously"

    requested_prefix = attrs[:issue_prefix] || attrs["issue_prefix"] || "LLM"
    issue_prefix = unique_project_prefix(requested_prefix)
    engineer_count = attrs[:engineer_count] || attrs["engineer_count"] || 2
    adapter = normalize_adapter(attrs[:adapter] || attrs["adapter"] || :codex)

    Repo.transaction(fn ->
      company =
        %Company{}
        |> Company.changeset(%{
          name: name,
          slug: unique_slug(name),
          description: "An autonomous AI company with a CEO, CTO, and engineering team.",
          status: "active",
          issue_prefix: issue_prefix,
          issue_counter: 1,
          budget_monthly_cents:
            attrs[:budget_monthly_cents] || attrs["budget_monthly_cents"] || 0,
          require_board_approval_for_new_agents: false,
          governance_config: %{
            "autonomy_mode" => "autonomous_default",
            "approval_gates" => ["budget_override", "dangerous_runtime_action"]
          },
          brand_color: "#5e6ad2"
        })
        |> Repo.insert!()

      project =
        %Project{}
        |> Project.changeset(%{
          company_id: company.id,
          name: "Company OS",
          description: "Default operating project for autonomous company work.",
          prefix: issue_prefix,
          status: :active,
          settings: %{"wip_limits" => %{"in_progress" => engineer_count + 2}}
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
          adapter: adapter,
          max_concurrent_jobs: 1,
          capabilities: %{
            "strategy" => true,
            "planning" => true,
            "budgeting" => true,
            "hiring" => true
          },
          instructions:
            "Own the company goal, break strategy into goals and issues, delegate through the CTO, and keep the company running without waiting for humans unless a configured governance gate is hit."
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
          adapter: adapter,
          max_concurrent_jobs: 2,
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
              name: "Engineer #{index}",
              title: "Software Engineer",
              role: :engineer,
              adapter: adapter,
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

      first_engineer = List.first(engineers, cto)

      seed_specs = [
        %{
          number: 1,
          title: "Create the first autonomous execution plan",
          description:
            "Break the company goal into CEO, CTO, and engineering work. Create follow-up issues for the first execution cycle.",
          priority: :critical,
          assignee_id: ceo.id,
          assigned_role: "ceo"
        },
        %{
          number: 2,
          title: "Set up the engineering environment and CI pipeline",
          description:
            "Establish the development environment, linting, formatting, and CI pipeline so engineers can ship reliably.",
          priority: :high,
          assignee_id: cto.id,
          assigned_role: "cto"
        },
        %{
          number: 3,
          title: "Define the technical architecture",
          description:
            "Research and document the core technical architecture: stack choices, data model, API surface, and deployment strategy.",
          priority: :high,
          assignee_id: cto.id,
          assigned_role: "cto"
        },
        %{
          number: 4,
          title: "Implement the first core feature",
          description:
            "Pick the highest-value feature from the execution plan and implement it end to end with tests.",
          priority: :medium,
          assignee_id: first_engineer.id,
          assigned_role: if(first_engineer == cto, do: "cto", else: "engineer")
        },
        %{
          number: 5,
          title: "Ship a working demo for stakeholder review",
          description:
            "Package the first iteration into a reviewable demo. Document what works, what's missing, and what's next.",
          priority: :medium,
          assignee_id: ceo.id,
          assigned_role: "ceo"
        }
      ]

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
        agents: [ceo, cto | engineers],
        seed_issues: seed_issues
      }
    end)
  end

  defp create_template_agent!(attrs) do
    %Agent{}
    |> Agent.changeset(
      Map.merge(attrs, %{
        status: :idle,
        context_mode: "company",
        runtime_config: %{"autonomous" => true}
      })
    )
    |> Repo.insert!()
  end

  defp normalize_adapter(adapter) when is_atom(adapter), do: adapter

  defp normalize_adapter(adapter) when is_binary(adapter) do
    try do
      String.to_existing_atom(adapter)
    rescue
      ArgumentError -> :codex
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
    candidate = "#{base}#{suffix}"

    if Repo.get_by(Project, prefix: candidate),
      do: unique_project_prefix(base, suffix + 1),
      else: candidate
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
    from(a in Cympho.Agents.Agent, where: a.company_id == ^company_id)
    |> Repo.all()
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

    cond do
      is_nil(invite) ->
        {:error, :not_found}

      CompanyInvite.expired?(invite) ->
        mark_invite_expired(invite)
        {:error, :expired}

      invite.status != "pending" ->
        {:error, :already_used}

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

  @secret_fields ~w(password_hash key_hash encrypted_value webhook_secret github_webhook_secret)

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
      exported_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      version: 1
    }
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
      preload: [:labels, comments: [:author_agent, :author_user], documents: [:revisions]]
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
      {k, _v} when k in @secret_fields -> {k, "***REDACTED***"}
      {k, v} when is_map(v) and is_struct(v) -> {k, scrub(v)}
      {k, v} -> {k, v}
    end)
  end

  # ── Import ──

  def import_company(data, opts \\ []) do
    slug_strategy = Keyword.get(opts, :slug_strategy, :suffix)
    import_company!(data, slug_strategy)
  end

  defp import_company!(%{company: company_data} = data, slug_strategy) do
    Repo.transaction(fn ->
      # Create company with retry loop for slug collision (handles race condition)
      {:ok, company} = create_company_with_retry(company_data, slug_strategy)

      # Import users first (memberships reference them)
      user_id_map = import_users(Map.get(data, :users, []), company.id)

      # Import memberships
      import_memberships(Map.get(data, :memberships, []), company.id, user_id_map)

      # Import labels (issues reference them)
      label_id_map = import_labels(Map.get(data, :labels, []), company.id)

      # Import projects
      project_id_map = import_projects(Map.get(data, :projects, []), company.id)

      # Import goals
      import_goals(Map.get(data, :goals, []), company.id, project_id_map)

      # Import agents
      agent_id_map = import_agents(Map.get(data, :agents, []), company.id)

      # Import issues
      issue_id_map =
        import_issues(
          Map.get(data, :issues, []),
          company.id,
          project_id_map,
          agent_id_map,
          label_id_map
        )

      %{
        company: company,
        id_maps: %{
          projects: project_id_map,
          agents: agent_id_map,
          issues: issue_id_map,
          labels: label_id_map,
          users: user_id_map
        }
      }
    end)
  end

  # Creates a company, retrying with a new slug suffix on unique constraint violation
  defp create_company_with_retry(company_data, slug_strategy, attempts \\ 1) do
    slug =
      case slug_strategy do
        :suffix -> "#{company_data.slug}-#{:rand.uniform(9999)}"
        :fail -> company_data.slug
      end

    attrs = %{
      name: company_data.name,
      slug: slug,
      logo_url: Map.get(company_data, :logo_url)
    }

    case create_company(attrs) do
      {:ok, _company} = result ->
        result

      {:error, %{errors: errors}} = error when is_list(errors) ->
        slug_error = Enum.find(errors, fn {field, _} -> field == :slug end)

        if slug_error && attempts < 10 do
          create_company_with_retry(company_data, slug_strategy, attempts + 1)
        else
          error
        end

      {:error, _} = error ->
        error
    end
  end

  # Returns map of old_user_id -> new_user_id
  defp import_users(users, company_id) do
    result =
      Enum.reduce(users, %{}, fn user_data, acc ->
        # Check if user with this email already exists
        existing_user = Repo.get_by(Cympho.Users.User, email: user_data.email)

        if existing_user do
          # Link to existing user - the membership will use the existing user
          {:ok, Map.put(acc, Map.get(user_data, :id), existing_user.id)}
        else
          # Create new user with a random password they must reset
          random_password = :crypto.strong_rand_bytes(16) |> Base.encode64()

          attrs = %{
            email: user_data.email,
            name: user_data.name,
            password: random_password,
            company_id: company_id
          }

          case Repo.insert(
                 %Cympho.Users.User{}
                 |> Cympho.Users.User.registration_changeset(attrs)
               ) do
            {:ok, user} -> {:ok, Map.put(acc, Map.get(user_data, :id), user.id)}
            {:error, changeset} -> {:error, changeset}
          end
        end
      end)

    case result do
      {:error, changeset} ->
        raise "User import failed: #{inspect(changeset.errors)}"

      id_map when is_map(id_map) ->
        id_map
    end
  end

  defp import_memberships(memberships, company_id, user_id_map) do
    Enum.each(memberships, fn membership_data ->
      new_user_id = remap_id(user_id_map, Map.get(membership_data, :user_id))

      # Skip if user wasn't imported (user_id_map doesn't have this user)
      if new_user_id do
        attrs = %{
          user_id: new_user_id,
          company_id: company_id,
          role: Map.get(membership_data, :role, "member")
        }

        case Repo.insert(%CompanyMembership{} |> CompanyMembership.changeset(attrs)) do
          {:ok, _membership} -> :ok
          {:error, changeset} -> raise "Membership import failed: #{inspect(changeset.errors)}"
        end
      end
    end)
  end

  defp import_labels(labels, company_id) do
    _errors = []

    result =
      Enum.reduce(labels, %{}, fn label_data, acc ->
        attrs = %{
          name: label_data.name,
          color: Map.get(label_data, :color, "#6B7280"),
          description: Map.get(label_data, :description),
          company_id: company_id
        }

        case Repo.insert(%Cympho.Labels.Label{} |> Cympho.Labels.Label.changeset(attrs)) do
          {:ok, label} -> Map.put(acc, Map.get(label_data, :id), label.id)
          {:error, changeset} -> {:error, changeset, acc}
        end
      end)

    case result do
      {:error, changeset, _acc} ->
        raise "Label import failed: #{inspect(changeset.errors)}"

      id_map when is_map(id_map) ->
        id_map
    end
  end

  defp import_projects(projects, company_id) do
    result =
      Enum.reduce(projects, %{}, fn project_data, acc ->
        {:ok, project} = create_project_with_retry(project_data, company_id)
        Map.put(acc, Map.get(project_data, :id), project.id)
      end)

    result
  end

  defp create_project_with_retry(project_data, company_id, attempts \\ 1) do
    prefix = "#{project_data.prefix}-#{:rand.uniform(99)}"

    attrs = %{
      name: project_data.name,
      description: Map.get(project_data, :description),
      prefix: prefix,
      settings: Map.get(project_data, :settings, %{}),
      company_id: company_id
    }

    case Repo.insert(%Cympho.Projects.Project{} |> Cympho.Projects.Project.changeset(attrs)) do
      {:ok, _project} = result ->
        result

      {:error, %{errors: errors}} = error when is_list(errors) ->
        prefix_error = Enum.find(errors, fn {field, _} -> field == :prefix end)

        if prefix_error && attempts < 10 do
          create_project_with_retry(project_data, company_id, attempts + 1)
        else
          {:error, error}
        end

      {:error, _} = error ->
        error
    end
  end

  defp import_goals(goals, company_id, project_id_map) do
    Enum.each(goals, fn goal_data ->
      attrs = %{
        title: goal_data.title,
        description: Map.get(goal_data, :description),
        status: Map.get(goal_data, :status, "active"),
        priority: Map.get(goal_data, :priority, "medium"),
        project_id: remap_id(project_id_map, Map.get(goal_data, :project_id)),
        company_id: company_id
      }

      Repo.insert(%Cympho.Goals.Goal{} |> Cympho.Goals.Goal.changeset(attrs))
    end)
  end

  defp import_agents(agents, company_id) do
    result =
      Enum.reduce(agents, %{}, fn agent_data, acc ->
        {:ok, agent} = create_agent_with_retry(agent_data, company_id)
        Map.put(acc, Map.get(agent_data, :id), agent.id)
      end)

    result
  end

  defp create_agent_with_retry(agent_data, company_id, attempts \\ 1) do
    url_key =
      case agent_data.url_key do
        nil -> nil
        _ -> "#{agent_data.url_key}-#{:rand.uniform(9999)}"
      end

    attrs = %{
      name: agent_data.name,
      url_key: url_key,
      role: Map.get(agent_data, :role, :engineer),
      config: Map.get(agent_data, :config, %{}),
      instructions: Map.get(agent_data, :instructions),
      company_id: company_id
    }

    case Repo.insert(%Cympho.Agents.Agent{} |> Cympho.Agents.Agent.changeset(attrs)) do
      {:ok, _agent} = result ->
        result

      {:error, %{errors: errors}} = error when is_list(errors) ->
        url_key_error = Enum.find(errors, fn {field, _} -> field == :url_key end)

        if url_key_error && attempts < 10 do
          create_agent_with_retry(agent_data, company_id, attempts + 1)
        else
          {:error, error}
        end

      {:error, _} = error ->
        error
    end
  end

  defp import_issues(issues, company_id, project_id_map, agent_id_map, label_id_map) do
    result =
      Enum.reduce(issues, %{}, fn issue_data, acc ->
        project_id = remap_id(project_id_map, Map.get(issue_data, :project_id))
        assignee_id = remap_id(agent_id_map, Map.get(issue_data, :assignee_id))

        attrs = %{
          title: Map.get(issue_data, :title),
          description: Map.get(issue_data, :description),
          status: Map.get(issue_data, :status, :backlog),
          priority: Map.get(issue_data, :priority, :medium),
          project_id: project_id,
          assignee_id: assignee_id,
          company_id: company_id
        }

        changeset = %Cympho.Issues.Issue{} |> Cympho.Issues.Issue.changeset(attrs)

        case Repo.insert(changeset) do
          {:ok, issue} ->
            old_id = Map.get(issue_data, :id)

            # Import labels
            labels = Map.get(issue_data, :labels, [])

            label_ids =
              Enum.map(labels, fn l -> remap_id(label_id_map, Map.get(l, :id)) end)
              |> Enum.filter(&(&1 != nil))

            if length(label_ids) > 0 do
              label_update =
                issue
                |> Repo.preload(:labels)
                |> Cympho.Issues.Issue.changeset(%{})
                |> Ecto.Changeset.put_assoc(
                  :labels,
                  Cympho.Repo.all(from l in Cympho.Labels.Label, where: l.id in ^label_ids)
                )
                |> Repo.update()

              case label_update do
                {:ok, _} ->
                  :ok

                {:error, changeset} ->
                  raise "Issue label import failed: #{inspect(changeset.errors)}"
              end
            end

            # Import comments
            comments = Map.get(issue_data, :comments, [])

            Enum.each(comments, fn c ->
              {author_type, author_id} =
                case Map.get(c, :author_type) do
                  "agent" ->
                    old_author_id = Map.get(c, :author_id)
                    # Only remap if the agent was actually imported (exists in agent_id_map)
                    if Map.has_key?(agent_id_map, old_author_id) do
                      {"agent", Map.get(agent_id_map, old_author_id)}
                    else
                      # Agent wasn't imported - use system author
                      {"system", nil}
                    end

                  other ->
                    {other || "system", Map.get(c, :author_id)}
                end

              comment_attrs = %{
                issue_id: issue.id,
                body: Map.get(c, :body, ""),
                author_type: author_type,
                author_id: author_id
              }

              case Repo.insert(
                     %Cympho.Comments.Comment{}
                     |> Cympho.Comments.Comment.changeset(comment_attrs)
                   ) do
                {:ok, _} -> :ok
                {:error, changeset} -> raise "Comment import failed: #{inspect(changeset.errors)}"
              end
            end)

            {:ok, Map.put(acc, old_id, issue.id)}

          {:error, changeset} ->
            {:error, changeset, acc}
        end
      end)

    case result do
      {:error, changeset, _acc} ->
        raise "Issue import failed: #{inspect(changeset.errors)}"

      id_map when is_map(id_map) ->
        id_map
    end
  end

  defp remap_id(_map, nil), do: nil

  defp remap_id(map, old_id) do
    Map.get(map, old_id, old_id)
  end
end
