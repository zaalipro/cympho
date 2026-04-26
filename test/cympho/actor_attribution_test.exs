defmodule Cympho.ActorAttributionTest do
  use Cympho.DataCase

  alias Cympho.ActorAttribution
  alias Cympho.Agents
  alias Cympho.Companies

  setup do
    {:ok, company} =
      Companies.create_company(%{
        name: "Test Company",
        prefix: "test-co",
        default_role: "member"
      })

    {:ok, agent} =
      Agents.create_agent(company, %{
        name: "Test Agent",
        role: "engineer",
        model: "claude-sonnet-4-6",
        status: :idle
      })

    %{company: company, agent: agent}
  end

  describe "extract_actor/1" do
    test "extracts actor from agent struct", %{agent: agent} do
      assert ActorAttribution.extract_actor(agent) == %{
               type: "agent",
               id: agent.id
             }
    end

    test "extracts actor from map with type and id" do
      actor_id = Ecto.UUID.generate()

      assert ActorAttribution.extract_actor(%{type: "user", id: actor_id}) == %{
               type: "user",
               id: actor_id
             }
    end

    test "extracts actor from string key map with type and id" do
      actor_id = Ecto.UUID.generate()

      assert ActorAttribution.extract_actor(%{"type" => "agent", "id" => actor_id}) == %{
               type: "agent",
               id: actor_id
             }
    end

    test "extracts actor from tuple" do
      actor_id = Ecto.UUID.generate()

      assert ActorAttribution.extract_actor({"user", actor_id}) == %{
               type: "user",
               id: actor_id
             }
    end

    test "extracts actor from map with actor_type and actor_id" do
      actor_id = Ecto.UUID.generate()

      assert ActorAttribution.extract_actor(%{
               actor_type: "agent",
               actor_id: actor_id
             }) == %{type: "agent", id: actor_id}
    end

    test "returns system actor for nil input" do
      assert ActorAttribution.extract_actor(nil) == %{
               type: "system",
               id: "00000000-0000-0000-0000-000000000000"
             }
    end

    test "returns system actor for invalid input" do
      assert ActorAttribution.extract_actor("invalid") == %{
               type: "system",
               id: "00000000-0000-0000-0000-000000000000"
             }
    end

    test "normalizes invalid UUID to nil UUID" do
      assert ActorAttribution.extract_actor({"user", "not-a-uuid"}) == %{
               type: "user",
               id: "00000000-0000-0000-0000-000000000000"
             }
    end
  end

  describe "to_db_attrs/1" do
    test "converts actor map to database attributes" do
      actor_id = Ecto.UUID.generate()

      assert ActorAttribution.to_db_attrs(%{type: "agent", id: actor_id}) == %{
               actor_type: "agent",
               actor_id: actor_id
             }
    end

    test "handles nil actor_id for system actors" do
      assert ActorAttribution.to_db_attrs(%{type: "system", id: nil}) == %{
               actor_type: "system",
               actor_id: nil
             }
    end
  end

  describe "normalize_actor_type/1" do
    test "normalizes agent type strings" do
      assert ActorAttribution.normalize_actor_type("Agent") == "agent"
      assert ActorAttribution.normalize_actor_type("AGENT") == "agent"
      assert ActorAttribution.normalize_actor_type(:agent) == "agent"
    end

    test "normalizes user type strings" do
      assert ActorAttribution.normalize_actor_type("User") == "user"
      assert ActorAttribution.normalize_actor_type("USER") == "user"
      assert ActorAttribution.normalize_actor_type(:user) == "user"
    end

    test "normalizes system type strings" do
      assert ActorAttribution.normalize_actor_type("System") == "system"
      assert ActorAttribution.normalize_actor_type("SYSTEM") == "system"
      assert ActorAttribution.normalize_actor_type(:system) == "system"
    end

    test "defaults invalid types to system" do
      assert ActorAttribution.normalize_actor_type("invalid") == "system"
      assert ActorAttribution.normalize_actor_type("admin") == "system"
    end
  end

  describe "is_actor_type?/2" do
    test "returns true when actor matches type" do
      actor = %{type: "agent", id: "123"}
      assert ActorAttribution.is_actor_type?(actor, "agent")
    end

    test "returns false when actor doesn't match type" do
      actor = %{type: "user", id: "123"}
      refute ActorAttribution.is_actor_type?(actor, "agent")
    end
  end

  describe "valid_uuid?/1" do
    test "returns true for valid UUIDs" do
      uuid = Ecto.UUID.generate()
      assert ActorAttribution.valid_uuid?(uuid)
    end

    test "returns false for invalid UUIDs" do
      refute ActorAttribution.valid_uuid?("not-a-uuid")
      refute ActorAttribution.valid_uuid?("12345678-1234-1234-1234-123456789abc")
    end

    test "returns false for non-strings" do
      refute ActorAttribution.valid_uuid?(123)
      refute ActorAttribution.valid_uuid?(nil)
    end
  end
end
