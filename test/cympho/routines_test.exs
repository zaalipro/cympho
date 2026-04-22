defmodule Cympho.RoutinesTest do
  use Cympho.DataCase, async: true

  alias Cympho.Routines
  alias Cympho.Routines.Routine

  describe "list_routines/0" do
    test "returns all routines ordered by inserted_at desc" do
      {:ok, r1} = Routines.create_routine(%{name: "First Routine"})
      {:ok, r2} = Routines.create_routine(%{name: "Second Routine"})

      routines = Routines.list_routines()
      ids = Enum.map(routines, & &1.id)
      assert r2.id in ids
      assert r1.id in ids
      # Most recent first
      assert Enum.find_index(routines, &(&1.id == r2.id)) <
             Enum.find_index(routines, &(&1.id == r1.id))
    end
  end

  describe "list_routines_by_status/1" do
    test "returns only routines with the given status" do
      {:ok, _active} = Routines.create_routine(%{name: "Active"})
      {:ok, _paused} =
        Routines.create_routine(%{name: "Paused", status: :paused})

      active = Routines.list_routines_by_status(:active)
      assert length(active) == 1
      assert hd(active).name == "Active"
    end
  end

  describe "get_routine!/1" do
    test "returns the routine with given id" do
      {:ok, routine} = Routines.create_routine(%{name: "Test Routine"})
      found = Routines.get_routine!(routine.id)
      assert found.id == routine.id
      assert found.name == "Test Routine"
    end

    test "raises Ecto.NoResultsError for non-existent id" do
      assert_raise Ecto.NoResultsError, fn ->
        Routines.get_routine!("00000000-0000-0000-0000-000000000000")
      end
    end
  end

  describe "get_routine/1" do
    test "returns {:ok, routine} for valid id" do
      {:ok, routine} = Routines.create_routine(%{name: "Test Routine"})
      assert {:ok, found} = Routines.get_routine(routine.id)
      assert found.id == routine.id
    end

    test "returns {:error, :not_found} for non-existent id" do
      assert {:error, :not_found} = Routines.get_routine("00000000-0000-0000-0000-000000000000")
    end
  end

  describe "create_routine/1" do
    test "creates routine with valid data" do
      attrs = %{
        name: "Daily Standup",
        description: "Run daily standup check",
        concurrency_policy: :skip_if_active,
        catch_up_policy: :enqueue_missed_with_cap,
        priority: :high
      }

      assert {:ok, %Routine{} = routine} = Routines.create_routine(attrs)
      assert routine.name == "Daily Standup"
      assert routine.description == "Run daily standup check"
      assert routine.status == :active
      assert routine.concurrency_policy == :skip_if_active
      assert routine.catch_up_policy == :enqueue_missed_with_cap
      assert routine.priority == :high
    end

    test "creates routine with defaults" do
      attrs = %{name: "Simple Routine"}
      assert {:ok, %Routine{} = routine} = Routines.create_routine(attrs)
      assert routine.status == :active
      assert routine.concurrency_policy == :coalesce_if_active
      assert routine.catch_up_policy == :skip_missed
      assert routine.priority == :medium
    end

    test "returns error changeset for missing name" do
      assert {:error, %Ecto.Changeset{}} = Routines.create_routine(%{})
    end

    test "returns error changeset for empty name" do
      assert {:error, %Ecto.Changeset{}} = Routines.create_routine(%{name: ""})
    end

    test "returns error changeset for name exceeding 200 characters" do
      long_name = String.duplicate("a", 201)
      assert {:error, %Ecto.Changeset{}} = Routines.create_routine(%{name: long_name})
    end
  end

  describe "update_routine/2" do
    test "updates routine with valid data" do
      {:ok, routine} = Routines.create_routine(%{name: "Original"})

      attrs = %{name: "Updated", description: "New description"}
      assert {:ok, updated} = Routines.update_routine(routine, attrs)
      assert updated.name == "Updated"
      assert updated.description == "New description"
    end

    test "returns error changeset for invalid data" do
      {:ok, routine} = Routines.create_routine(%{name: "Test"})
      assert {:error, %Ecto.Changeset{}} = Routines.update_routine(routine, %{name: ""})
    end
  end

  describe "pause_routine/1" do
    test "pauses an active routine" do
      {:ok, routine} = Routines.create_routine(%{name: "Test"})
      assert {:ok, paused} = Routines.pause_routine(routine)
      assert paused.status == :paused
    end

    test "returns error when pausing a paused routine" do
      {:ok, routine} = Routines.create_routine(%{name: "Test", status: :paused})
      assert {:error, :invalid_transition} = Routines.pause_routine(routine)
    end

    test "returns error when pausing an archived routine" do
      {:ok, routine} = Routines.create_routine(%{name: "Test"})
      {:ok, archived} = Routines.archive_routine(routine)
      assert {:error, :invalid_transition} = Routines.pause_routine(archived)
    end
  end

  describe "resume_routine/1" do
    test "resumes a paused routine" do
      {:ok, routine} = Routines.create_routine(%{name: "Test"})
      {:ok, paused} = Routines.pause_routine(routine)
      assert {:ok, resumed} = Routines.resume_routine(paused)
      assert resumed.status == :active
    end

    test "returns error when resuming an active routine" do
      {:ok, routine} = Routines.create_routine(%{name: "Test"})
      assert {:error, :invalid_transition} = Routines.resume_routine(routine)
    end

    test "returns error when resuming an archived routine" do
      {:ok, routine} = Routines.create_routine(%{name: "Test"})
      {:ok, archived} = Routines.archive_routine(routine)
      assert {:error, :invalid_transition} = Routines.resume_routine(archived)
    end
  end

  describe "archive_routine/1" do
    test "archives an active routine" do
      {:ok, routine} = Routines.create_routine(%{name: "Test"})
      assert {:ok, archived} = Routines.archive_routine(routine)
      assert archived.status == :archived
    end

    test "archives a paused routine" do
      {:ok, routine} = Routines.create_routine(%{name: "Test"})
      {:ok, paused} = Routines.pause_routine(routine)
      assert {:ok, archived} = Routines.archive_routine(paused)
      assert archived.status == :archived
    end

    test "returns error when archiving an already archived routine" do
      {:ok, routine} = Routines.create_routine(%{name: "Test"})
      {:ok, archived} = Routines.archive_routine(routine)
      assert {:error, :invalid_transition} = Routines.archive_routine(archived)
    end
  end

  describe "delete_routine/1" do
    test "deletes the routine" do
      {:ok, routine} = Routines.create_routine(%{name: "Test"})
      assert {:ok, _} = Routines.delete_routine(routine)

      assert_raise Ecto.NoResultsError, fn ->
        Routines.get_routine!(routine.id)
      end
    end
  end

  describe "change_routine/2" do
    test "returns a changeset" do
      {:ok, routine} = Routines.create_routine(%{name: "Test"})
      changeset = Routines.change_routine(routine, %{name: "New Name"})
      assert changeset.changes[:name] == "New Name"
    end
  end

  describe "Routine.valid_next_statuses/1" do
    test "returns valid transitions for active" do
      {:ok, routine} = Routines.create_routine(%{name: "Test"})
      assert Routine.valid_next_statuses(routine) == [:paused, :archived]
    end

    test "returns valid transitions for paused" do
      {:ok, routine} = Routines.create_routine(%{name: "Test", status: :paused})
      assert Routine.valid_next_statuses(routine) == [:active, :archived]
    end

    test "returns empty list for archived" do
      {:ok, routine} = Routines.create_routine(%{name: "Test"})
      {:ok, archived} = Routines.archive_routine(routine)
      assert Routine.valid_next_statuses(archived) == []
    end
  end

  describe "Routine.transition_allowed?/2" do
    test "active -> paused is allowed" do
      {:ok, routine} = Routines.create_routine(%{name: "Test"})
      assert Routine.transition_allowed?(routine, :paused)
    end

    test "active -> archived is allowed" do
      {:ok, routine} = Routines.create_routine(%{name: "Test"})
      assert Routine.transition_allowed?(routine, :archived)
    end

    test "active -> active is not allowed" do
      {:ok, routine} = Routines.create_routine(%{name: "Test"})
      refute Routine.transition_allowed?(routine, :active)
    end

    test "archived -> active is not allowed" do
      {:ok, routine} = Routines.create_routine(%{name: "Test"})
      {:ok, archived} = Routines.archive_routine(routine)
      refute Routine.transition_allowed?(archived, :active)
    end
  end
end
