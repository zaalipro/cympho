defmodule Cympho.ProjectsTest do
  use Cympho.DataCase, async: true

  alias Cympho.Projects
  alias Cympho.Projects.Project

  describe "list_projects/0" do
    test "returns all projects" do
      {:ok, project} = Projects.create_project(%{
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
      {:ok, project} = Projects.create_project(%{
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
      {:ok, project} = Projects.create_project(%{
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
      {:ok, project} = Projects.create_project(%{
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
      {:ok, project} = Projects.create_project(%{
        name: "Original Name",
        prefix: "ORIG"
      })

      attrs = %{name: "Updated Name", status: :archived}
      assert {:ok, updated} = Projects.update_project(project, attrs)
      assert updated.name == "Updated Name"
      assert updated.status == :archived
    end

    test "returns error changeset for invalid data" do
      {:ok, project} = Projects.create_project(%{
        name: "Test",
        prefix: "TST"
      })

      attrs = %{name: ""}
      assert {:error, %Ecto.Changeset{}} = Projects.update_project(project, attrs)
    end
  end

  describe "archive_project/1" do
    test "archives the project" do
      {:ok, project} = Projects.create_project(%{
        name: "Test",
        prefix: "TST"
      })

      assert {:ok, archived} = Projects.archive_project(project)
      assert archived.status == :archived
    end
  end

  describe "delete_project/1" do
    test "deletes the project" do
      {:ok, project} = Projects.create_project(%{
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
      {:ok, project} = Projects.create_project(%{
        name: "Test",
        prefix: "TST"
      })

      changeset = Projects.change_project(project, %{name: "New Name"})
      assert changeset.changes[:name] == "New Name"
    end
  end
end