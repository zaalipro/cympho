defmodule Cympho.CompaniesPortabilityTest do
  use Cympho.DataCase, async: true

  alias Cympho.Agents.Agent
  alias Cympho.Agents
  alias Cympho.Authentication
  alias Cympho.Comments.Comment
  alias Cympho.Companies
  alias Cympho.Companies.{Company, CompanyMembership}
  alias Cympho.Goals
  alias Cympho.Goals.Goal
  alias Cympho.Issues.Issue
  alias Cympho.Labels
  alias Cympho.Labels.Label
  alias Cympho.Projects
  alias Cympho.Projects.Project
  alias Cympho.Secrets
  alias Cympho.Users.User

  describe "preview_import/2" do
    test "returns an exact V1 plan without writing records or exposing secret values" do
      slug = unique_slug("portable-preview")
      {:ok, _existing_company} = Companies.create_company(%{name: "Existing", slug: slug})

      {:ok, existing_user} =
        Authentication.register_user(%{
          email: "preview-#{System.unique_integer([:positive])}@example.test",
          name: "Existing operator",
          password: "password123"
        })

      package = valid_package(slug, existing_user.email)
      before_counts = record_counts()

      assert {:ok, plan} = Companies.preview_import(package, slug_strategy: :suffix)

      assert record_counts() == before_counts
      assert plan.version == 1
      assert plan.ready?

      assert plan.target == %{
               requested_slug: slug,
               slug: "#{slug}-copy",
               strategy: :suffix,
               collision?: true,
               status: :ready,
               action: :create_with_suffix
             }

      assert plan.inventory == %{
               companies: 1,
               users: 1,
               users_to_create: 0,
               users_to_reuse: 1,
               memberships: 1,
               projects: 1,
               agents: 1,
               issues: 1,
               comments: 1,
               issue_label_assignments: 1,
               goals: 1,
               labels: 1,
               ignored_documents: 0,
               secret_restore_requirements: 1,
               package_records: 10,
               planned_writes: 9
             }

      assert [requirement] = plan.secret_restore_requirements
      assert requirement.key == "PROJECT_TOKEN"
      assert requirement.scope == "project"
      assert requirement.original_scope_id == "project-1"
      assert requirement.will_remap_scope?
      assert requirement.restore_status == "requires_value"
      refute Map.has_key?(requirement, :value)
      refute inspect(plan) =~ "must-never-render"

      warning_codes = Enum.map(plan.warnings, & &1.code)
      assert :slug_collision_resolved in warning_codes
      assert :existing_users_reused in warning_codes
    end

    test "rejects unsupported versions without writes" do
      package = valid_package(unique_slug("future-package"), unique_email())
      package = Map.put(package, "version", 2)
      before_counts = record_counts()

      assert {:error, %{supported_versions: [1], errors: errors}} =
               Companies.preview_import(package)

      assert Enum.any?(errors, &(&1.code == :unsupported_version and &1.field == "version"))
      assert {:error, message} = Companies.import_company(package)
      assert message =~ "Export version 2 is not supported"
      assert record_counts() == before_counts
    end

    test "fail strategy produces a blocked collision plan and prevents import" do
      slug = unique_slug("blocked-preview")
      {:ok, _existing_company} = Companies.create_company(%{name: "Existing", slug: slug})
      package = valid_package(slug, unique_email())
      before_counts = record_counts()

      assert {:ok, plan} = Companies.preview_import(package, slug_strategy: :fail)
      refute plan.ready?
      assert plan.target.status == :blocked
      assert plan.target.slug == slug
      assert Enum.any?(plan.warnings, &(&1.code == :slug_collision_blocked))

      assert {:error, message} = Companies.import_company(package, slug_strategy: :fail)
      assert message =~ "fail strategy blocks import"
      assert record_counts() == before_counts
    end

    test "rejects unredacted credentials without echoing their values" do
      leaked_value = "provider-secret-must-not-echo"

      package =
        valid_package(unique_slug("unsafe-package"), unique_email())
        |> put_in(["agents", Access.at(0), "config"], %{"api_key" => leaked_value})

      assert {:error, %{errors: errors} = error} = Companies.preview_import(package)
      assert Enum.any?(errors, &(&1.code == :unredacted_secret_values))
      refute inspect(error) =~ leaked_value
    end

    test "allows manifest key identifiers but rejects manifest credential payloads" do
      package = valid_package(unique_slug("manifest-metadata"), unique_email())

      assert {:ok, plan} = Companies.preview_import(package)
      assert [%{key: "PROJECT_TOKEN"}] = plan.secret_restore_requirements

      credential_fields = [
        "value",
        "encrypted_blob",
        "digest_hash",
        "authorization",
        "refresh_token",
        "client_credential"
      ]

      Enum.each(credential_fields, fn field_name ->
        leaked_value = "manifest-#{field_name}-must-not-echo"
        unsafe = put_in(package, ["secret_manifest", Access.at(0), field_name], leaked_value)

        assert {:error, %{errors: errors} = error} = Companies.preview_import(unsafe)
        assert Enum.any?(errors, &(&1.code == :unredacted_secret_values))
        refute inspect(error) =~ leaked_value
      end)
    end
  end

  describe "import integrity" do
    test "a valid V1 export round-trips with exact writes and tenant-scoped relationships" do
      slug = unique_slug("round-trip")
      {:ok, company} = Companies.create_company(%{name: "Round Trip Source", slug: slug})

      {:ok, user} =
        Authentication.register_user(%{
          email: unique_email(),
          name: "Round Trip Owner",
          password: "password123",
          company_id: company.id
        })

      {:ok, _membership} =
        %CompanyMembership{}
        |> CompanyMembership.changeset(%{
          company_id: company.id,
          user_id: user.id,
          role: "owner",
          is_board_member: true
        })
        |> Repo.insert()

      {:ok, project} =
        Projects.create_project(%{
          name: "Round Trip Project",
          prefix: unique_prefix(),
          company_id: company.id
        })

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Round Trip Agent",
          role: :engineer,
          company_id: company.id,
          project_id: project.id,
          config: %{"safe_setting" => "preserved", "api_key" => "never-export-agent-key"}
        })

      {:ok, goal} =
        Goals.create_goal(%{
          title: "Round Trip Goal",
          company_id: company.id,
          project_id: project.id
        })

      {:ok, issue} =
        %Issue{}
        |> Issue.changeset(%{
          title: "Round Trip Issue",
          description: "Exercise all V1 relationship maps",
          company_id: company.id,
          project_id: project.id,
          goal_id: goal.id,
          assignee_id: agent.id,
          created_by_user_id: user.id
        })
        |> Repo.insert()

      {:ok, label} =
        Labels.create_label(%{
          name: "round-trip-#{System.unique_integer([:positive])}",
          color: "#336699",
          company_id: company.id
        })

      {:ok, _issue} =
        issue
        |> Repo.preload(:labels)
        |> Issue.changeset(%{})
        |> put_assoc(:labels, [label])
        |> Repo.update()

      {:ok, _agent_comment} =
        %Comment{}
        |> Comment.changeset(%{
          issue_id: issue.id,
          body: "Agent-authored portable comment",
          author_type: "agent",
          author_id: agent.id
        })
        |> Repo.insert()

      {:ok, _user_comment} =
        %Comment{}
        |> Comment.changeset(%{
          issue_id: issue.id,
          body: "User-authored portable comment",
          author_type: "user",
          author_id: user.id
        })
        |> Repo.insert()

      {:ok, _secret} =
        Secrets.create_secret(%{
          company_id: company.id,
          scope: "project",
          scope_id: project.id,
          key: "ROUND_TRIP_TOKEN",
          value: "never-export-project-token"
        })

      package = company.id |> Companies.export_company() |> Jason.encode!() |> Jason.decode!()
      refute inspect(package) =~ "never-export-agent-key"
      refute inspect(package) =~ "never-export-project-token"

      before_counts = record_counts()
      assert {:ok, preview} = Companies.preview_import(package)
      assert preview.inventory.package_records == 11
      assert preview.inventory.planned_writes == 10

      assert {:ok, result} = Companies.import_company(package)
      imported_company = result.company
      after_counts = record_counts()

      assert count_delta(before_counts, after_counts) == %{
               agents: 1,
               comments: 2,
               companies: 1,
               goals: 1,
               issue_labels: 1,
               issues: 1,
               labels: 1,
               memberships: 1,
               projects: 1,
               users: 0
             }

      imported_project = Repo.get!(Project, Map.fetch!(result.id_maps.projects, project.id))
      imported_agent = Repo.get!(Agent, Map.fetch!(result.id_maps.agents, agent.id))
      imported_goal = Repo.get!(Goal, Map.fetch!(result.id_maps.goals, goal.id))

      imported_issue =
        Issue
        |> Repo.get!(Map.fetch!(result.id_maps.issues, issue.id))
        |> Repo.preload([:labels, :comments])

      assert imported_project.company_id == imported_company.id
      assert imported_agent.company_id == imported_company.id
      assert imported_agent.project_id == imported_project.id
      assert imported_goal.company_id == imported_company.id
      assert imported_goal.project_id == imported_project.id
      assert imported_issue.company_id == imported_company.id
      assert imported_issue.project_id == imported_project.id
      assert imported_issue.assignee_id == imported_agent.id
      assert imported_issue.goal_id == imported_goal.id
      assert imported_issue.created_by_user_id == user.id
      assert [%Label{company_id: imported_company_id}] = imported_issue.labels
      assert imported_company_id == imported_company.id

      assert Enum.find(imported_issue.comments, &(&1.author_type == "agent")).author_id ==
               imported_agent.id

      assert Enum.find(imported_issue.comments, &(&1.author_type == "user")).author_id == user.id

      assert Repo.exists?(
               from membership in CompanyMembership,
                 where:
                   membership.company_id == ^imported_company.id and
                     membership.user_id == ^user.id
             )

      assert Secrets.list_secrets(imported_company.id) == []

      assert [restore] = result.secrets_to_restore
      assert restore.key == "ROUND_TRIP_TOKEN"
      assert restore.original_scope_id == project.id
      assert restore.scope_id == imported_project.id
      refute Map.has_key?(restore, :value)
    end

    test "rejects every unmapped relationship before it can cross company boundaries" do
      {:ok, foreign_company} =
        Companies.create_company(%{
          name: "Foreign Relationship Company",
          slug: unique_slug("foreign-relationship")
        })

      {:ok, foreign_user} =
        Authentication.register_user(%{
          email: unique_email(),
          name: "Foreign User",
          password: "password123",
          company_id: foreign_company.id
        })

      {:ok, foreign_project} =
        Projects.create_project(%{
          name: "Foreign Project",
          prefix: unique_prefix(),
          company_id: foreign_company.id
        })

      {:ok, foreign_agent} =
        Agents.create_agent(%{
          name: "Foreign Agent",
          role: :engineer,
          company_id: foreign_company.id
        })

      {:ok, foreign_label} =
        Labels.create_label(%{
          name: "foreign-label-#{System.unique_integer([:positive])}",
          company_id: foreign_company.id
        })

      mutations = [
        fn package ->
          put_in(package, ["memberships", Access.at(0), "user_id"], foreign_user.id)
        end,
        fn package ->
          put_in(package, ["goals", Access.at(0), "project_id"], foreign_project.id)
        end,
        fn package ->
          put_in(package, ["issues", Access.at(0), "project_id"], foreign_project.id)
        end,
        fn package ->
          put_in(package, ["issues", Access.at(0), "assignee_id"], foreign_agent.id)
        end,
        fn package ->
          put_in(
            package,
            ["issues", Access.at(0), "labels", Access.at(0), "id"],
            foreign_label.id
          )
        end,
        fn package ->
          put_in(
            package,
            ["issues", Access.at(0), "comments", Access.at(0), "author_id"],
            foreign_agent.id
          )
        end,
        fn package ->
          put_in(package, ["secret_manifest", Access.at(0), "scope_id"], foreign_project.id)
        end
      ]

      Enum.each(mutations, fn mutate ->
        package = valid_package(unique_slug("unmapped"), unique_email()) |> mutate.()
        before_counts = record_counts()

        assert {:error, %{errors: errors}} = Companies.preview_import(package)
        assert Enum.any?(errors, &(&1.code == :unmapped_reference))
        assert {:error, message} = Companies.import_company(package)
        assert message =~ "must reference a record included in this import package"
        assert record_counts() == before_counts
      end)
    end

    test "label, goal, issue, and comment failures each roll back the whole import" do
      invalid_records = [
        {"Label",
         fn package ->
           put_in(package, ["labels", Access.at(0), "color"], "not-a-color")
         end},
        {"Goal",
         fn package ->
           put_in(package, ["goals", Access.at(0), "status"], "not-a-status")
         end},
        {"Issue",
         fn package ->
           put_in(package, ["issues", Access.at(0), "status"], "not-a-status")
         end},
        {"Comment",
         fn package ->
           put_in(package, ["issues", Access.at(0), "comments", Access.at(0), "body"], "")
         end}
      ]

      Enum.each(invalid_records, fn {record_type, invalidate} ->
        package = valid_package(unique_slug("rollback"), unique_email()) |> invalidate.()
        assert {:ok, _preview} = Companies.preview_import(package)
        before_counts = record_counts()

        assert {:error, message} = Companies.import_company(package)
        assert message =~ "#{record_type} import failed"
        assert record_counts() == before_counts
      end)
    end
  end

  defp valid_package(slug, user_email) do
    label_name = String.slice("portable-#{slug}", 0, 50)

    %{
      "version" => 1,
      "company" => %{"name" => "Portable Preview", "slug" => slug},
      "users" => [%{"id" => "user-1", "email" => user_email, "name" => "Operator"}],
      "memberships" => [%{"id" => "membership-1", "user_id" => "user-1", "role" => "owner"}],
      "projects" => [%{"id" => "project-1", "name" => "Portable Project", "prefix" => "PRT"}],
      "agents" => [
        %{
          "id" => "agent-1",
          "name" => "Portable Agent",
          "role" => "engineer",
          "config" => %{}
        }
      ],
      "issues" => [
        %{
          "id" => "issue-1",
          "title" => "Portable issue",
          "project_id" => "project-1",
          "assignee_id" => "agent-1",
          "comments" => [
            %{
              "id" => "comment-1",
              "body" => "Portable comment",
              "author_type" => "agent",
              "author_id" => "agent-1"
            }
          ],
          "labels" => [%{"id" => "label-1", "name" => label_name}]
        }
      ],
      "goals" => [
        %{
          "id" => "goal-1",
          "title" => "Portable goal",
          "project_id" => "project-1"
        }
      ],
      "labels" => [%{"id" => "label-1", "name" => label_name, "color" => "#6B7280"}],
      "secret_manifest" => [
        %{
          "key" => "PROJECT_TOKEN",
          "scope" => "project",
          "scope_id" => "project-1"
        }
      ]
    }
  end

  defp record_counts do
    %{
      companies: Repo.aggregate(Company, :count, :id),
      users: Repo.aggregate(User, :count, :id),
      memberships: Repo.aggregate(CompanyMembership, :count, :id),
      projects: Repo.aggregate(Project, :count, :id),
      agents: Repo.aggregate(Agent, :count, :id),
      issues: Repo.aggregate(Issue, :count, :id),
      comments: Repo.aggregate(Comment, :count, :id),
      issue_labels: Repo.one(from issue_label in "issue_labels", select: count()),
      goals: Repo.aggregate(Goal, :count, :id),
      labels: Repo.aggregate(Label, :count, :id)
    }
  end

  defp count_delta(before_counts, after_counts) do
    Map.new(before_counts, fn {key, before_count} ->
      {key, Map.fetch!(after_counts, key) - before_count}
    end)
  end

  defp unique_slug(prefix),
    do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp unique_email,
    do: "portable-#{System.unique_integer([:positive])}@example.test"

  defp unique_prefix do
    number = System.unique_integer([:positive])
    "P" <> alphabetic_prefix(number)
  end

  defp alphabetic_prefix(number) when number > 0 do
    number
    |> Stream.unfold(fn
      0 -> nil
      value -> {<<?A + rem(value - 1, 26)>>, div(value - 1, 26)}
    end)
    |> Enum.reverse()
    |> Enum.join()
    |> String.slice(0, 9)
  end
end
