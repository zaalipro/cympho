defmodule Cympho.AuthHardeningPr2Test do
  @moduledoc """
  PR 2 (REQ-002): write paths whitelist fields and API keys compare in
  constant time.
  """
  use Cympho.DataCase, async: true

  alias Cympho.Agents
  alias Cympho.Agents.AgentApiKey
  alias Cympho.Users.User

  describe "Agent.update_changeset/2 (AC-012)" do
    test "ignores authorization- and ledger-sensitive fields on a request update" do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Original",
          role: :engineer,
          status: :idle,
          governance_status: "active",
          spent_monthly_cents: 0
        })

      attrs = %{
        "name" => "Renamed",
        "governance_status" => "terminated",
        "spent_monthly_cents" => 999_999,
        "requires_board_approval" => true,
        "company_id" => Ecto.UUID.generate(),
        "capabilities" => ["root"]
      }

      assert {:ok, updated} = Agents.update_agent(agent, attrs)

      # The safe field is updated...
      assert updated.name == "Renamed"
      # ...but the sensitive ones are untouched.
      assert updated.governance_status == "active"
      assert updated.spent_monthly_cents == 0
      assert updated.requires_board_approval == agent.requires_board_approval
      assert updated.company_id == agent.company_id
      assert updated.capabilities == agent.capabilities
    end
  end

  describe "User.changeset/2 (AC-013)" do
    test "does not cast company_id" do
      changeset =
        User.changeset(%User{}, %{
          "name" => "Nick",
          "email" => "nick@example.com",
          "company_id" => Ecto.UUID.generate()
        })

      refute Map.has_key?(changeset.changes, :company_id)
    end
  end

  describe "AgentApiKey.valid_api_key?/2 (AC-014)" do
    test "accepts the matching key and rejects others" do
      key = AgentApiKey.generate_api_key()
      hash = AgentApiKey.hash_api_key(key)

      assert AgentApiKey.valid_api_key?(key, hash)
      refute AgentApiKey.valid_api_key?("not-the-key", hash)
      refute AgentApiKey.valid_api_key?(key, nil)
    end
  end
end
