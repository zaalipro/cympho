defmodule Cympho.ActivitiesTest do
  use Cympho.DataCase, async: true

  alias Cympho.Activities
  alias Cympho.Issues
  alias Cympho.Comments

  describe "log_activity/1" do
    test "creates an activity record" do
      {:ok, issue} = Issues.create_issue(%{title: "Test Issue", description: "Test desc"})

      {:ok, activity} =
        Activities.log_activity(%{
          issue_id: issue.id,
          actor_type: "system",
          action: "status_changed",
          metadata: %{"from" => "backlog", "to" => "todo"}
        })

      assert activity.issue_id == issue.id
      assert activity.actor_type == "system"
      assert activity.action == "status_changed"
      assert activity.metadata["from"] == "backlog"
    end

    test "validates required fields" do
      {:error, changeset} = Activities.log_activity(%{action: "created"})
      assert errors_on(changeset)[:issue_id]
      assert errors_on(changeset)[:actor_type]
    end

    test "validates actor_type inclusion" do
      {:ok, issue} = Issues.create_issue(%{title: "T", description: "D"})

      {:error, changeset} =
        Activities.log_activity(%{
          issue_id: issue.id,
          actor_type: "invalid",
          action: "created"
        })

      assert errors_on(changeset)[:actor_type]
    end

    test "validates action inclusion" do
      {:ok, issue} = Issues.create_issue(%{title: "T", description: "D"})

      {:error, changeset} =
        Activities.log_activity(%{
          issue_id: issue.id,
          actor_type: "system",
          action: "invalid_action"
        })

      assert errors_on(changeset)[:action]
    end
  end

  describe "list_activities/1" do
    test "returns activities ordered chronologically" do
      {:ok, issue} = Issues.create_issue(%{title: "Test Issue", description: "Test desc"})

      activities = Activities.list_activities(issue.id)
      assert length(activities) >= 1
      [first | _] = activities
      assert first.action == "created"
    end

    test "returns empty for nonexistent issue" do
      activities = Activities.list_activities(Ecto.UUID.generate())
      assert activities == []
    end
  end

  describe "activity logging on issue operations" do
    test "create_issue logs 'created' activity" do
      {:ok, issue} = Issues.create_issue(%{title: "New Issue", description: "New desc"})
      activities = Activities.list_activities(issue.id)
      created = Enum.find(activities, &(&1.action == "created"))
      assert created != nil
    end

    test "update_issue with title change logs 'title_changed'" do
      {:ok, issue} = Issues.create_issue(%{title: "Original Title", description: "Test desc"})
      {:ok, _updated} = Issues.update_issue(issue, %{title: "Updated Title"})
      activities = Activities.list_activities(issue.id)
      title_change = Enum.find(activities, &(&1.action == "title_changed"))
      assert title_change != nil
    end

    test "update_issue with status change logs 'status_changed'" do
      {:ok, issue} = Issues.create_issue(%{title: "Test", description: "Test desc"})
      {:ok, _updated} = Issues.update_issue(issue, %{status: :todo})
      activities = Activities.list_activities(issue.id)
      status_change = Enum.find(activities, &(&1.action == "status_changed"))
      assert status_change != nil
    end

    test "update_issue with no changes does not create extra activities" do
      {:ok, issue} = Issues.create_issue(%{title: "Test", description: "Test desc"})
      initial_count = length(Activities.list_activities(issue.id))
      {:ok, _updated} = Issues.update_issue(issue, %{title: "Test"})
      assert length(Activities.list_activities(issue.id)) == initial_count
    end
  end

  describe "activity logging on blocker operations" do
    test "add_blocker logs 'blocker_added'" do
      {:ok, blocked} = Issues.create_issue(%{title: "Blocked", description: "Blocked desc"})
      {:ok, blocker} = Issues.create_issue(%{title: "Blocker", description: "Blocker desc"})
      {:ok, _} = Issues.add_blocker(blocked, blocker)
      activities = Activities.list_activities(blocked.id)
      blocker_added = Enum.find(activities, &(&1.action == "blocker_added"))
      assert blocker_added != nil
    end

    test "remove_blocker logs 'blocker_removed'" do
      {:ok, blocked} = Issues.create_issue(%{title: "Blocked", description: "Blocked desc"})
      {:ok, blocker} = Issues.create_issue(%{title: "Blocker", description: "Blocker desc"})
      {:ok, _} = Issues.add_blocker(blocked, blocker)
      {:ok, _} = Issues.remove_blocker(blocked, blocker)
      activities = Activities.list_activities(blocked.id)
      blocker_removed = Enum.find(activities, &(&1.action == "blocker_removed"))
      assert blocker_removed != nil
    end
  end

  describe "activity logging on comment creation" do
    test "create_comment logs 'comment_added'" do
      {:ok, issue} = Issues.create_issue(%{title: "Test Issue", description: "Test desc"})

      {:ok, _comment} =
        Comments.create_comment(%{
          body: "Test comment",
          author_type: "agent",
          author_id: "agent-1",
          issue_id: issue.id
        })

      activities = Activities.list_activities(issue.id)
      comment_added = Enum.find(activities, &(&1.action == "comment_added"))
      assert comment_added != nil
      assert comment_added.actor_type == "agent"
      assert comment_added.actor_id == "agent-1"
    end
  end
end
