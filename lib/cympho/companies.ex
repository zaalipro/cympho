defmodule Cympho.Companies do
  import Ecto.Query, warn: false
  alias Cympho.Repo
  alias Cympho.Companies.Company
  alias Cympho.Companies.CompanyMembership
  alias Cympho.Companies.CompanyInvite
  alias Cympho.Companies.JoinRequest

  # ── Company CRUD ──

  def list_companies do
    Repo.all(Company)
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
    company
    |> Company.changeset(attrs)
    |> Repo.update()
  end

  def delete_company(%Company{} = company) do
    Repo.delete(company)
  end

  def change_company(%Company{} = company, attrs \\ %{}) do
    Company.changeset(company, attrs)
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
      membership -> membership.is_board_member
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

  defp create_membership!(attrs) do
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
      # Resolve slug collision
      slug = resolve_slug_collision(company_data.slug, slug_strategy)

      {:ok, company} =
        create_company(%{
          name: company_data.name,
          slug: slug,
          logo_url: Map.get(company_data, :logo_url)
        })

      # Import labels first (issues reference them)
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

      %{company: company, id_maps: %{projects: project_id_map, agents: agent_id_map, issues: issue_id_map, labels: label_id_map}}
    end)
  end

  defp resolve_slug_collision(slug, :suffix) do
    if Repo.get_by(Company, slug: slug) do
      resolve_slug_collision("#{slug}-#{:rand.uniform(9999)}", :suffix)
    else
      slug
    end
  end

  defp resolve_slug_collision(slug, :fail) do
    if Repo.get_by(Company, slug: slug) do
      raise "Slug collision: #{slug}"
    else
      slug
    end
  end

  defp import_labels(labels, company_id) do
    Enum.reduce(labels, %{}, fn label_data, acc ->
      attrs = %{
        name: label_data.name,
        color: Map.get(label_data, :color, "#6B7280"),
        description: Map.get(label_data, :description),
        company_id: company_id
      }

      case Repo.insert(%Cympho.Labels.Label{} |> Cympho.Labels.Label.changeset(attrs)) do
        {:ok, label} -> Map.put(acc, Map.get(label_data, :id), label.id)
        {:error, _} -> acc
      end
    end)
  end

  defp import_projects(projects, company_id) do
    Enum.reduce(projects, %{}, fn project_data, acc ->
      prefix = resolve_prefix_collision(project_data.prefix)

      attrs = %{
        name: project_data.name,
        description: Map.get(project_data, :description),
        prefix: prefix,
        settings: Map.get(project_data, :settings, %{}),
        company_id: company_id
      }

      case Repo.insert(%Cympho.Projects.Project{} |> Cympho.Projects.Project.changeset(attrs)) do
        {:ok, project} -> Map.put(acc, Map.get(project_data, :id), project.id)
        {:error, _} -> acc
      end
    end)
  end

  defp resolve_prefix_collision(prefix) do
    if Repo.get_by(Cympho.Projects.Project, prefix: prefix) do
      resolve_prefix_collision("#{prefix}#{:rand.uniform(9)}")
    else
      prefix
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
    Enum.reduce(agents, %{}, fn agent_data, acc ->
      url_key = resolve_url_key_collision(agent_data.url_key)

      attrs = %{
        name: agent_data.name,
        url_key: url_key,
        role: Map.get(agent_data, :role, :engineer),
        config: Map.get(agent_data, :config, %{}),
        instructions: Map.get(agent_data, :instructions),
        company_id: company_id
      }

      case Repo.insert(%Cympho.Agents.Agent{} |> Cympho.Agents.Agent.changeset(attrs)) do
        {:ok, agent} -> Map.put(acc, Map.get(agent_data, :id), agent.id)
        {:error, _} -> acc
      end
    end)
  end

  defp resolve_url_key_collision(nil), do: nil

  defp resolve_url_key_collision(url_key) do
    if Repo.get_by(Cympho.Agents.Agent, url_key: url_key) do
      resolve_url_key_collision("#{url_key}-#{:rand.uniform(9999)}")
    else
      url_key
    end
  end

  defp import_issues(issues, company_id, project_id_map, agent_id_map, label_id_map) do
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
          label_ids = Enum.map(labels, fn l -> remap_id(label_id_map, Map.get(l, :id)) end)
                             |> Enum.filter(&(&1 != nil))

          if length(label_ids) > 0 do
            issue
            |> Repo.preload(:labels)
            |> Cympho.Issues.Issue.changeset(%{})
            |> Ecto.Changeset.put_assoc(:labels, Cympho.Repo.all(from l in Cympho.Labels.Label, where: l.id in ^label_ids))
            |> Repo.update()
          end

          # Import comments
          comments = Map.get(issue_data, :comments, [])
          Enum.each(comments, fn c ->
            {author_type, author_id} =
              case Map.get(c, :author_type) do
                "agent" ->
                  {"agent", remap_id(agent_id_map, Map.get(c, :author_id))}

                other ->
                  {other || "system", Map.get(c, :author_id)}
              end

            Repo.insert(%Cympho.Comments.Comment{} |> Cympho.Comments.Comment.changeset(%{
              issue_id: issue.id,
              body: Map.get(c, :body, ""),
              author_type: author_type,
              author_id: author_id
            }))
          end)

          Map.put(acc, old_id, issue.id)

        {:error, _} ->
          acc
      end
    end)
  end

  defp remap_id(_map, nil), do: nil

  defp remap_id(map, old_id) do
    Map.get(map, old_id, old_id)
  end
end
