defmodule Cympho.LabelsTest do
  use Cympho.DataCase, async: true

  alias Cympho.Labels
  alias Cympho.Labels.Label
  alias Cympho.Projects
  alias Cympho.Issues

  setup do
    {:ok, project} = Projects.create_project(%{name: "Test Project", prefix: "TLP"})
    %{project: project}
  end

  describe "list_labels/0" do
    test "returns all labels", %{project: project} do
      {:ok, _label} = Labels.create_label(%{name: "Bug", color: "#FF0000", project_id: project.id})
      {:ok, _label2} = Labels.create_label(%{name: "Feature", color: "#00FF00", project_id: project.id})

      labels = Labels.list_labels()
      assert length(labels) >= 2
    end
  end

  describe "list_labels/1" do
    test "filters by project_id", %{project: project} do
      {:ok, _label} = Labels.create_label(%{name: "Bug", color: "#FF0000", project_id: project.id})

      {:ok, other_project} = Projects.create_project(%{name: "Other", prefix: "OTP"})
      {:ok, _other_label} = Labels.create_label(%{name: "Other Bug", color: "#0000FF", project_id: other_project.id})

      labels = Labels.list_labels(project_id: project.id)
      assert length(labels) == 1
      assert hd(labels).name == "Bug"
    end
  end

  describe "get_label!/1" do
    test "returns the label with given id", %{project: project} do
      {:ok, label} = Labels.create_label(%{name: "Bug", color: "#FF0000", project_id: project.id})
      found = Labels.get_label!(label.id)
      assert found.id == label.id
      assert found.name == "Bug"
      assert found.color == "#FF0000"
    end

    test "raises Ecto.NoResultsError for non-existent id" do
      assert_raise Ecto.NoResultsError, fn ->
        Labels.get_label!("00000000-0000-0000-0000-000000000000")
      end
    end
  end

  describe "get_label/1" do
    test "returns {:ok, label} for valid id", %{project: project} do
      {:ok, label} = Labels.create_label(%{name: "Bug", color: "#FF0000", project_id: project.id})
      assert {:ok, found} = Labels.get_label(label.id)
      assert found.id == label.id
    end

    test "returns {:error, :not_found} for non-existent id" do
      assert {:error, :not_found} = Labels.get_label("00000000-0000-0000-0000-000000000000")
    end
  end

  describe "create_label/1" do
    test "creates label with valid data", %{project: project} do
      attrs = %{name: "Enhancement", color: "#3B82F6", project_id: project.id}
      assert {:ok, %Label{} = label} = Labels.create_label(attrs)
      assert label.name == "Enhancement"
      assert label.color == "#3B82F6"
    end

    test "creates label with default color", %{project: project} do
      attrs = %{name: "Default", project_id: project.id}
      assert {:ok, %Label{} = label} = Labels.create_label(attrs)
      assert label.color == "#6b7280"
    end

    test "returns error with missing name", %{project: project} do
      attrs = %{color: "#FF0000", project_id: project.id}
      assert {:error, changeset} = Labels.create_label(attrs)
      assert "can't be blank" in errors_on(changeset).name
    end

    test "returns error with missing project_id" do
      attrs = %{name: "Bug", color: "#FF0000"}
      assert {:error, changeset} = Labels.create_label(attrs)
      assert "can't be blank" in errors_on(changeset).project_id
    end

    test "returns error with invalid color format" do
      attrs = %{name: "Bug", color: "red", project_id: Ecto.UUID.generate()}
      assert {:error, changeset} = Labels.create_label(attrs)
      assert "must be a hex color" in errors_on(changeset).color
    end

    test "returns error for duplicate name in same project", %{project: project} do
      {:ok, _} = Labels.create_label(%{name: "Bug", color: "#FF0000", project_id: project.id})
      assert {:error, changeset} = Labels.create_label(%{name: "Bug", color: "#00FF00", project_id: project.id})
      assert "has already been taken" in errors_on(changeset).name
    end

    test "allows same name in different projects" do
      {:ok, project1} = Projects.create_project(%{name: "P1", prefix: "P1T"})
      {:ok, project2} = Projects.create_project(%{name: "P2", prefix: "P2T"})
      assert {:ok, _} = Labels.create_label(%{name: "Bug", color: "#FF0000", project_id: project1.id})
      assert {:ok, _} = Labels.create_label(%{name: "Bug", color: "#00FF00", project_id: project2.id})
    end

    test "returns error with name too long" do
      attrs = %{name: String.duplicate("a", 101), project_id: Ecto.UUID.generate()}
      assert {:error, changeset} = Labels.create_label(attrs)
      assert "should be at most 100 character(s)" in errors_on(changeset).name
    end
  end

  describe "update_label/2" do
    test "updates label name", %{project: project} do
      {:ok, label} = Labels.create_label(%{name: "Bug", color: "#FF0000", project_id: project.id})
      assert {:ok, updated} = Labels.update_label(label, %{name: "Defect"})
      assert updated.name == "Defect"
    end

    test "updates label color", %{project: project} do
      {:ok, label} = Labels.create_label(%{name: "Bug", color: "#FF0000", project_id: project.id})
      assert {:ok, updated} = Labels.update_label(label, %{color: "#00FF00"})
      assert updated.color == "#00FF00"
    end

    test "returns error with invalid data", %{project: project} do
      {:ok, label} = Labels.create_label(%{name: "Bug", color: "#FF0000", project_id: project.id})
      assert {:error, changeset} = Labels.update_label(label, %{name: ""})
      assert "can't be blank" in errors_on(changeset).name
    end
  end

  describe "delete_label/1" do
    test "deletes a label", %{project: project} do
      {:ok, label} = Labels.create_label(%{name: "Bug", color: "#FF0000", project_id: project.id})
      assert {:ok, %Label{}} = Labels.delete_label(label)
      assert {:error, :not_found} = Labels.get_label(label.id)
    end
  end

  describe "change_label/2" do
    test "returns a changeset", %{project: project} do
      {:ok, label} = Labels.create_label(%{name: "Bug", color: "#FF0000", project_id: project.id})
      assert %Ecto.Changeset{} = Labels.change_label(label)
    end
  end

  describe "issue-label operations" do
    setup %{project: project} do
      {:ok, issue} = Issues.create_issue(%{
        title: "Test Issue",
        description: "Test description",
        project_id: project.id
      })
      {:ok, label} = Labels.create_label(%{name: "Bug", color: "#FF0000", project_id: project.id})
      %{issue: issue, label: label, project: project}
    end

    test "list_labels_for_issue/1 returns labels for an issue", %{issue: issue} do
      labels = Labels.list_labels_for_issue(issue)
      assert labels == []
    end

    test "add_label_to_issue/2 adds a label to an issue", %{issue: issue, label: label} do
      assert {:ok, updated} = Labels.add_label_to_issue(issue, label)
      labels = Labels.list_labels_for_issue(updated)
      assert length(labels) == 1
      assert hd(labels).id == label.id
    end

    test "add_label_to_issue/2 is idempotent", %{issue: issue, label: label} do
      {:ok, _} = Labels.add_label_to_issue(issue, label)
      {:ok, updated} = Labels.add_label_to_issue(issue, label)
      labels = Labels.list_labels_for_issue(updated)
      assert length(labels) == 1
    end

    test "remove_label_from_issue/2 removes a label from an issue", %{issue: issue, label: label} do
      {:ok, issue} = Labels.add_label_to_issue(issue, label)
      assert {:ok, updated} = Labels.remove_label_from_issue(issue, label)
      labels = Labels.list_labels_for_issue(updated)
      assert labels == []
    end

    test "set_issue_labels/2 replaces all labels on an issue", %{issue: issue, project: project} do
      {:ok, label1} = Labels.create_label(%{name: "Bug", color: "#FF0000", project_id: project.id})
      {:ok, label2} = Labels.create_label(%{name: "Feature", color: "#00FF00", project_id: project.id})

      {:ok, issue} = Labels.add_label_to_issue(issue, label1)
      assert {:ok, updated} = Labels.set_issue_labels(issue, [label2.id])
      labels = Labels.list_labels_for_issue(updated)
      assert length(labels) == 1
      assert hd(labels).id == label2.id
    end
  end
end
