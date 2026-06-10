defmodule Cympho.ProjectsTest do
  use Cympho.DataCase, async: true

  alias Cympho.Companies
  alias Cympho.Goals
  alias Cympho.Issues
  alias Cympho.Projects
  alias Cympho.Projects.Project

  describe "list_projects/0" do
    test "returns all projects" do
      {:ok, project} =
        Projects.create_project(%{
          name: "Test Project",
          prefix: "TST",
          status: :active
        })

      projects = Projects.list_projects()
      assert length(projects) >= 1
      assert Enum.any?(projects, fn p -> p.id == project.id end)
    end
  end

  describe "get_project!/1" do
    test "returns the project with given id" do
      {:ok, project} =
        Projects.create_project(%{
          name: "Test Project",
          prefix: "TST"
        })

      found = Projects.get_project!(project.id)
      assert found.id == project.id
      assert found.name == project.name
    end

    test "raises Ecto.NoResultsError for non-existent id" do
      assert_raise Ecto.NoResultsError, fn ->
        Projects.get_project!("00000000-0000-0000-0000-000000000000")
      end
    end
  end

  describe "get_project/1" do
    test "returns {:ok, project} for valid id" do
      {:ok, project} =
        Projects.create_project(%{
          name: "Test Project",
          prefix: "TST"
        })

      assert {:ok, found} = Projects.get_project(project.id)
      assert found.id == project.id
    end

    test "returns {:error, :not_found} for non-existent id" do
      assert {:error, :not_found} = Projects.get_project("00000000-0000-0000-0000-000000000000")
    end
  end

  describe "get_project_by_prefix/1" do
    test "returns {:ok, project} for valid prefix" do
      {:ok, project} =
        Projects.create_project(%{
          name: "Test Project",
          prefix: "TST"
        })

      assert {:ok, found} = Projects.get_project_by_prefix("TST")
      assert found.id == project.id
    end

    test "returns {:error, :not_found} for unknown prefix" do
      assert {:error, :not_found} = Projects.get_project_by_prefix("UNKNOWN")
    end
  end

  describe "create_project/1" do
    test "creates project with valid data" do
      attrs = %{
        name: "New Project",
        prefix: "NEW",
        description: "A new project"
      }

      assert {:ok, %Project{} = project} = Projects.create_project(attrs)
      assert project.name == "New Project"
      assert project.prefix == "NEW"
      assert project.description == "A new project"
      assert project.status == :active
    end

    test "creates project with default status" do
      attrs = %{
        name: "New Project",
        prefix: "NP"
      }

      assert {:ok, %Project{} = project} = Projects.create_project(attrs)
      assert project.status == :active
    end

    test "returns error changeset for invalid data (missing name)" do
      attrs = %{prefix: "NO"}
      assert {:error, %Ecto.Changeset{}} = Projects.create_project(attrs)
    end

    test "returns error changeset for invalid prefix (lowercase)" do
      attrs = %{name: "Test", prefix: "lowercase"}
      assert {:error, %Ecto.Changeset{}} = Projects.create_project(attrs)
    end

    test "returns error changeset for prefix too short" do
      attrs = %{name: "Test", prefix: "A"}
      assert {:error, %Ecto.Changeset{}} = Projects.create_project(attrs)
    end

    test "returns error changeset for duplicate prefix" do
      attrs = %{name: "First", prefix: "DUPE"}
      assert {:ok, _} = Projects.create_project(attrs)

      attrs2 = %{name: "Second", prefix: "DUPE"}
      assert {:error, %Ecto.Changeset{}} = Projects.create_project(attrs2)
    end
  end

  describe "update_project/2" do
    test "updates project with valid data" do
      {:ok, project} =
        Projects.create_project(%{
          name: "Original Name",
          prefix: "ORIG"
        })

      attrs = %{name: "Updated Name", status: :archived}
      assert {:ok, updated} = Projects.update_project(project, attrs)
      assert updated.name == "Updated Name"
      assert updated.status == :archived
    end

    test "returns error changeset for invalid data" do
      {:ok, project} =
        Projects.create_project(%{
          name: "Test",
          prefix: "TST"
        })

      attrs = %{name: ""}
      assert {:error, %Ecto.Changeset{}} = Projects.update_project(project, attrs)
    end
  end

  describe "archive_project/1" do
    test "archives the project" do
      {:ok, project} =
        Projects.create_project(%{
          name: "Test",
          prefix: "TST"
        })

      assert {:ok, archived} = Projects.archive_project(project)
      assert archived.status == :archived
    end
  end

  describe "delete_project/1" do
    test "deletes the project" do
      {:ok, project} =
        Projects.create_project(%{
          name: "Test",
          prefix: "TST"
        })

      assert {:ok, _} = Projects.delete_project(project)

      assert_raise Ecto.NoResultsError, fn ->
        Projects.get_project!(project.id)
      end
    end
  end

  describe "change_project/2" do
    test "returns a changeset" do
      {:ok, project} =
        Projects.create_project(%{
          name: "Test",
          prefix: "TST"
        })

      changeset = Projects.change_project(project, %{name: "New Name"})
      assert changeset.changes[:name] == "New Name"
    end
  end

  describe "project_operating_snapshot/1" do
    test "summarizes project issue health, goals, and owner attention signals" do
      {:ok, company} =
        Companies.create_company(%{
          name: "Project Health Corp",
          slug: "project-health-#{System.unique_integer([:positive])}"
        })

      {:ok, other_company} =
        Companies.create_company(%{
          name: "Other Project Health Corp",
          slug: "other-project-health-#{System.unique_integer([:positive])}"
        })

      {:ok, project} =
        Projects.create_project(%{
          name: "Core Platform",
          prefix: "PHA",
          company_id: company.id
        })

      {:ok, idle_project} =
        Projects.create_project(%{
          name: "Idle Project",
          prefix: "PHB",
          repo_url: "https://github.com/example/idle",
          company_id: company.id
        })

      {:ok, foreign_project} =
        Projects.create_project(%{
          name: "Foreign Project",
          prefix: "PHC",
          company_id: other_company.id
        })

      {:ok, _active_goal} =
        Goals.create_goal(%{
          title: "Ship core platform",
          company_id: company.id,
          project_id: project.id,
          goal_type: :mission
        })

      {:ok, _completed_goal} =
        Goals.create_goal(%{
          title: "Old goal",
          company_id: company.id,
          project_id: project.id,
          goal_type: :mission,
          status: "completed"
        })

      for status <- [:todo, :in_review, :blocked, :done, :cancelled] do
        {:ok, _issue} =
          Issues.create_issue(%{
            title: "Project health #{status}",
            company_id: company.id,
            project_id: project.id,
            status: status
          })
      end

      {:ok, _foreign_issue} =
        Issues.create_issue(%{
          title: "Foreign project issue",
          company_id: other_company.id,
          project_id: foreign_project.id,
          status: :blocked
        })

      snapshot = Projects.project_operating_snapshot(company.id)
      health = snapshot.health[project.id]

      assert snapshot.overview.total_projects == 2
      assert snapshot.overview.active_projects == 2
      assert snapshot.overview.open_issues == 3
      assert snapshot.overview.blocked_projects == 1
      assert snapshot.overview.review_projects == 1
      assert snapshot.overview.idle_projects == 1
      assert snapshot.overview.missing_repo_projects == 1
      assert snapshot.overview.active_goals == 1
      assert snapshot.overview.status == :blocked

      assert health.total == 5
      assert health.open == 3
      assert health.in_review == 1
      assert health.blocked == 1
      assert health.done == 1
      assert health.cancelled == 1
      assert health.goals == 2
      assert health.active_goals == 1
      assert health.progress_percent == 20
      assert %DateTime{} = health.last_activity_at

      refute Map.has_key?(snapshot.health, idle_project.id)
      assert Projects.project_operating_snapshot(nil).overview.status == :empty
    end
  end
end
