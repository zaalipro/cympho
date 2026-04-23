defmodule Cympho.IssuesLabelsTest do
  use Cympho.DataCase
  alias Cympho.Issues
  alias Cympho.Labels
  alias Cympho.Projects

  setup do
    {:ok, project} = Projects.create_project(%{name: "Test", prefix: "TST"})
    {:ok, issue} = Issues.create_issue(%{title: "Test", description: "Desc", project_id: project.id})
    {:ok, label} = Labels.create_label(%{name: "Bug", color: "#FF0000"})
    {:ok, label2} = Labels.create_label(%{name: "Feature", color: "#00FF00"})
    %{issue: issue, label: label, label2: label2, project: project}
  end

  test "filter by single label_id", %{issue: issue, label: label} do
    {:ok, _} = Issues.add_label_to_issue(issue, label)
    result = Issues.list_issues(%{label_id: label.id})
    assert length(result) == 1
    assert hd(result).id == issue.id
  end

  test "filter by multiple label_ids AND", %{issue: issue, label: label, label2: label2} do
    {:ok, _} = Issues.add_label_to_issue(issue, label)
    {:ok, issue2} = Issues.create_issue(%{title: "Other", description: "Desc2", project_id: issue.project_id})
    {:ok, _} = Issues.add_label_to_issue(issue2, label)
    {:ok, _} = Issues.add_label_to_issue(issue2, label2)
    result = Issues.list_issues(%{label_ids: [label.id, label2.id]})
    assert length(result) == 1
    assert hd(result).id == issue2.id
  end

  test "no filter returns all" do
    assert length(Issues.list_issues(%{})) >= 1
  end

  test "add_label_to_issue/2", %{issue: issue, label: label} do
    assert {:ok, updated} = Issues.add_label_to_issue(issue, label)
    assert length(updated.labels) == 1
  end

  test "remove_label_from_issue/2", %{issue: issue, label: label} do
    {:ok, updated} = Issues.add_label_to_issue(issue, label)
    {:ok, updated} = Issues.remove_label_from_issue(updated, label)
    assert updated.labels == []
  end

  test "set_issue_labels/2 replaces", %{issue: issue, label: label, label2: label2} do
    {:ok, _} = Issues.add_label_to_issue(issue, label)
    {:ok, updated} = Issues.set_issue_labels(issue, [label2.id])
    assert length(updated.labels) == 1
    assert hd(updated.labels).id == label2.id
  end
end
