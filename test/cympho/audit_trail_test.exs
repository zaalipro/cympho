defmodule Cympho.AuditTrailTest do
  use Cympho.DataCase

  alias Cympho.AuditTrail
  alias Cympho.AuditTrail.AuditEvent
  alias Cympho.Companies

  describe "record_event/1" do
    test "records a valid audit event" do
      company = create_test_company()
      actor_id = Ecto.UUID.generate()
      resource_id = Ecto.UUID.generate()

      attrs = %{
        company_id: company.id,
        event_type: "issue_state_transition",
        actor_type: "agent",
        actor_id: actor_id,
        resource_type: "issue",
        resource_id: resource_id,
        payload: %{"from" => "queued", "to" => "in_progress"},
        ip_address: "10.0.0.1"
      }

      assert {:ok, %AuditEvent{} = event} = AuditTrail.record_event(attrs)
      assert event.company_id == company.id
      assert event.event_type == "issue_state_transition"
      assert event.actor_type == "agent"
      assert event.actor_id == actor_id
      assert event.resource_type == "issue"
      assert event.resource_id == resource_id
      assert event.payload == %{"from" => "queued", "to" => "in_progress"}
      assert event.ip_address == "10.0.0.1"
    end

    test "requires required fields" do
      attrs = %{}

      assert {:error, %Ecto.Changeset{}} = AuditTrail.record_event(attrs)
    end

    test "validates event_type" do
      company = create_test_company()

      attrs = %{
        company_id: company.id,
        event_type: "invalid_event_type",
        actor_type: "agent",
        actor_id: Ecto.UUID.generate(),
        resource_type: "issue",
        resource_id: Ecto.UUID.generate()
      }

      assert {:error, %Ecto.Changeset{}} = AuditTrail.record_event(attrs)
    end

    test "validates actor_type" do
      company = create_test_company()

      attrs = %{
        company_id: company.id,
        event_type: "issue_state_transition",
        actor_type: "invalid_actor_type",
        actor_id: Ecto.UUID.generate(),
        resource_type: "issue",
        resource_id: Ecto.UUID.generate()
      }

      assert {:error, %Ecto.Changeset{}} = AuditTrail.record_event(attrs)
    end

    test "validates resource_type" do
      company = create_test_company()

      attrs = %{
        company_id: company.id,
        event_type: "issue_state_transition",
        actor_type: "agent",
        actor_id: Ecto.UUID.generate(),
        resource_type: "invalid_resource_type",
        resource_id: Ecto.UUID.generate()
      }

      assert {:error, %Ecto.Changeset{}} = AuditTrail.record_event(attrs)
    end
  end

  describe "list_company_events/2" do
    setup do
      company = create_test_company()
      agent_id_1 = Ecto.UUID.generate()
      agent_id_2 = Ecto.UUID.generate()
      user_id = Ecto.UUID.generate()
      issue_id_1 = Ecto.UUID.generate()
      issue_id_2 = Ecto.UUID.generate()

      # Create some test events
      {:ok, _event1} =
        AuditTrail.record_event(%{
          company_id: company.id,
          event_type: "issue_state_transition",
          actor_type: "agent",
          actor_id: agent_id_1,
          resource_type: "issue",
          resource_id: issue_id_1,
          payload: %{"from" => "queued", "to" => "in_progress"}
        })

      {:ok, _event2} =
        AuditTrail.record_event(%{
          company_id: company.id,
          event_type: "agent_paused",
          actor_type: "user",
          actor_id: user_id,
          resource_type: "agent",
          resource_id: agent_id_1
        })

      {:ok, _event3} =
        AuditTrail.record_event(%{
          company_id: company.id,
          event_type: "issue_state_transition",
          actor_type: "agent",
          actor_id: agent_id_2,
          resource_type: "issue",
          resource_id: issue_id_2,
          payload: %{"from" => "in_progress", "to" => "completed"}
        })

      %{company: company, agent_id_1: agent_id_1, issue_id_1: issue_id_1}
    end

    test "returns all events for a company", %{company: company} do
      {events, total} = AuditTrail.list_company_events(company.id)
      assert total == 3
      assert length(events) == 3
    end

    test "filters by event_type", %{company: company} do
      {events, total} =
        AuditTrail.list_company_events(company.id, event_type: "issue_state_transition")

      assert total == 2
      assert length(events) == 2
      assert Enum.all?(events, &(&1.event_type == "issue_state_transition"))
    end

    test "filters by actor_type", %{company: company} do
      {events, total} = AuditTrail.list_company_events(company.id, actor_type: "agent")
      assert total == 2
      assert length(events) == 2
    end

    test "filters by actor_id", %{company: company, agent_id_1: agent_id_1} do
      {events, total} = AuditTrail.list_company_events(company.id, actor_id: agent_id_1)
      assert total == 1
      assert length(events) == 1
      assert hd(events).actor_id == agent_id_1
    end

    test "filters by resource_type", %{company: company} do
      {events, total} = AuditTrail.list_company_events(company.id, resource_type: "issue")
      assert total == 2
      assert length(events) == 2
    end

    test "filters by resource_id", %{company: company, issue_id_1: issue_id_1} do
      {events, total} = AuditTrail.list_company_events(company.id, resource_id: issue_id_1)
      assert total == 1
      assert length(events) == 1
      assert hd(events).resource_id == issue_id_1
    end

    test "applies limit and offset", %{company: company} do
      {events, total} = AuditTrail.list_company_events(company.id, limit: 2, offset: 0)
      assert total == 3
      assert length(events) == 2
    end

    test "orders by inserted_at descending", %{company: company} do
      {events, _total} = AuditTrail.list_company_events(company.id)
      assert length(events) >= 2

      # Check that events are ordered by inserted_at descending
      insert_times = Enum.map(events, & &1.inserted_at)
      assert insert_times == Enum.sort(insert_times, {:desc, NaiveDateTime})
    end
  end

  describe "list_resource_history/3" do
    setup do
      company = create_test_company()
      issue_id = Ecto.UUID.generate()

      # Create events for the same resource
      {:ok, _event1} =
        AuditTrail.record_event(%{
          company_id: company.id,
          event_type: "issue_state_transition",
          actor_type: "agent",
          actor_id: Ecto.UUID.generate(),
          resource_type: "issue",
          resource_id: issue_id,
          payload: %{"from" => "queued", "to" => "in_progress"}
        })

      {:ok, _event2} =
        AuditTrail.record_event(%{
          company_id: company.id,
          event_type: "issue_assigned",
          actor_type: "user",
          actor_id: Ecto.UUID.generate(),
          resource_type: "issue",
          resource_id: issue_id
        })

      {:ok, _event3} =
        AuditTrail.record_event(%{
          company_id: company.id,
          event_type: "comment_created",
          actor_type: "agent",
          actor_id: Ecto.UUID.generate(),
          resource_type: "issue",
          resource_id: Ecto.UUID.generate()
        })

      %{company: company, issue_id: issue_id}
    end

    test "returns history for a specific resource", %{issue_id: issue_id} do
      events = AuditTrail.list_resource_history(issue_id, "issue")
      assert length(events) == 2
      assert Enum.all?(events, &(&1.resource_id == issue_id))
      assert Enum.all?(events, &(&1.resource_type == "issue"))
    end
  end

  describe "list_actor_history/3" do
    setup do
      company = create_test_company()
      agent_id = Ecto.UUID.generate()

      # Create events by the same actor
      {:ok, _event1} =
        AuditTrail.record_event(%{
          company_id: company.id,
          event_type: "issue_state_transition",
          actor_type: "agent",
          actor_id: agent_id,
          resource_type: "issue",
          resource_id: Ecto.UUID.generate()
        })

      {:ok, _event2} =
        AuditTrail.record_event(%{
          company_id: company.id,
          event_type: "agent_paused",
          actor_type: "agent",
          actor_id: agent_id,
          resource_type: "agent",
          resource_id: Ecto.UUID.generate()
        })

      # Create event by a different actor
      {:ok, _event3} =
        AuditTrail.record_event(%{
          company_id: company.id,
          event_type: "issue_assigned",
          actor_type: "user",
          actor_id: Ecto.UUID.generate(),
          resource_type: "issue",
          resource_id: Ecto.UUID.generate()
        })

      %{company: company, agent_id: agent_id}
    end

    test "returns history for a specific actor", %{agent_id: agent_id} do
      events = AuditTrail.list_actor_history(agent_id, "agent")
      assert length(events) == 2
      assert Enum.all?(events, &(&1.actor_id == agent_id))
      assert Enum.all?(events, &(&1.actor_type == "agent"))
    end

    test "filters by company_id when provided", %{company: company, agent_id: agent_id} do
      events = AuditTrail.list_actor_history(agent_id, "agent", company_id: company.id)
      assert length(events) == 2
    end
  end

  describe "get_statistics/2" do
    setup do
      company = create_test_company()
      agent_id = Ecto.UUID.generate()
      user_id = Ecto.UUID.generate()

      # Create various events
      {:ok, _event1} =
        AuditTrail.record_event(%{
          company_id: company.id,
          event_type: "issue_state_transition",
          actor_type: "agent",
          actor_id: agent_id,
          resource_type: "issue",
          resource_id: Ecto.UUID.generate()
        })

      {:ok, _event2} =
        AuditTrail.record_event(%{
          company_id: company.id,
          event_type: "issue_state_transition",
          actor_type: "agent",
          actor_id: agent_id,
          resource_type: "issue",
          resource_id: Ecto.UUID.generate()
        })

      {:ok, _event3} =
        AuditTrail.record_event(%{
          company_id: company.id,
          event_type: "agent_paused",
          actor_type: "user",
          actor_id: user_id,
          resource_type: "agent",
          resource_id: Ecto.UUID.generate()
        })

      %{company: company}
    end

    test "returns statistics for a company" do
      stats = AuditTrail.get_statistics(Ecto.UUID.generate())
      assert stats.total == 0
      assert stats.by_event_type == %{}
      assert stats.by_actor_type == %{}
    end

    test "returns statistics for the company with events", %{company: company} do
      stats = AuditTrail.get_statistics(company.id)
      assert stats.total == 3
      assert stats.by_event_type == %{"agent_paused" => 1, "issue_state_transition" => 2}
      assert stats.by_actor_type == %{"agent" => 2, "user" => 1}
    end

    test "filters by date range", %{company: company} do
      start_date = NaiveDateTime.utc_now() |> NaiveDateTime.add(-3600)
      end_date = NaiveDateTime.utc_now() |> NaiveDateTime.add(3600)

      stats = AuditTrail.get_statistics(company.id, start_date: start_date, end_date: end_date)
      assert stats.total == 3
    end
  end

  describe "immutability" do
    test "prevents UPDATE on audit_events" do
      company = create_test_company()

      {:ok, event} =
        AuditTrail.record_event(%{
          company_id: company.id,
          event_type: "issue_state_transition",
          actor_type: "agent",
          actor_id: Ecto.UUID.generate(),
          resource_type: "issue",
          resource_id: Ecto.UUID.generate()
        })

      assert_raise Postgrex.Error, ~r/Audit events are immutable/, fn ->
        Cympho.Repo.update(Ecto.Changeset.change(event, %{ip_address: "1.2.3.4"}))
      end
    end

    test "prevents DELETE on audit_events" do
      company = create_test_company()

      {:ok, event} =
        AuditTrail.record_event(%{
          company_id: company.id,
          event_type: "issue_state_transition",
          actor_type: "agent",
          actor_id: Ecto.UUID.generate(),
          resource_type: "issue",
          resource_id: Ecto.UUID.generate()
        })

      assert_raise Postgrex.Error, ~r/Audit events are immutable/, fn ->
        Cympho.Repo.delete(event)
      end
    end
  end

  defp create_test_company do
    {:ok, company} =
      Companies.create_company(%{
        name: "Test Company",
        slug: "test-company-#{System.unique_integer()}",
        issue_prefix: "TEST"
      })

    company
  end
end
