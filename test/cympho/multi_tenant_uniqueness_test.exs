defmodule Cympho.MultiTenantUniquenessTest do
  use Cympho.DataCase, async: true

  alias Cympho.{Companies, Decisions, Labels, Projects, Repo}
  alias Cympho.ToolCallTraces.ToolCallTrace

  defp create_company(tag) do
    unique = System.unique_integer([:positive])

    {:ok, company} =
      Companies.create_company(%{
        name: "Tenant #{tag} #{unique}",
        slug: "tenant-#{tag}-#{unique}"
      })

    company
  end

  setup do
    %{a: create_company("a"), b: create_company("b")}
  end

  describe "labels" do
    test "two companies can each own a label named 'bug'", %{a: a, b: b} do
      assert {:ok, _} = Labels.create_label(%{name: "bug", color: "#ff0000", company_id: a.id})
      assert {:ok, _} = Labels.create_label(%{name: "bug", color: "#00ff00", company_id: b.id})
    end

    test "a single company still cannot duplicate a label name", %{a: a} do
      assert {:ok, _} = Labels.create_label(%{name: "dupe", color: "#ff0000", company_id: a.id})

      assert {:error, %Ecto.Changeset{}} =
               Labels.create_label(%{name: "dupe", color: "#0000ff", company_id: a.id})
    end
  end

  describe "projects" do
    test "two companies can each use prefix 'ENG'", %{a: a, b: b} do
      assert {:ok, _} = Projects.create_project(%{name: "Eng A", prefix: "ENG", company_id: a.id})
      assert {:ok, _} = Projects.create_project(%{name: "Eng B", prefix: "ENG", company_id: b.id})
    end

    test "a single company still cannot duplicate a prefix", %{a: a} do
      assert {:ok, _} = Projects.create_project(%{name: "One", prefix: "DUP", company_id: a.id})

      assert {:error, %Ecto.Changeset{}} =
               Projects.create_project(%{name: "Two", prefix: "DUP", company_id: a.id})
    end
  end

  describe "decisions" do
    # Regression guard, not a bug fix: the old index was
    # UNIQUE (decision_key, parent_decision_id) WHERE status='active', and
    # Postgres treats NULLs as distinct, so top-level keys never collided
    # across tenants — verified against the pre-migration schema. Scoping the
    # index by company aligns it with validate_decision_key_unique/1, which was
    # already company-scoped; this test locks in the behaviour either way.
    test "two companies can hold the same active decision_key", %{a: a, b: b} do
      attrs = fn company_id ->
        %{
          company_id: company_id,
          decision_key: "arch_v1",
          decision_type: "architecture",
          outcome: "approved",
          actor_type: "system",
          actor_id: Ecto.UUID.generate(),
          status: "active"
        }
      end

      assert {:ok, _} = Decisions.create_decision(attrs.(a.id))
      assert {:ok, _} = Decisions.create_decision(attrs.(b.id))
    end
  end

  describe "tool call traces" do
    # content_hash excludes company_id, agent_id and run_id, and occurred_at is
    # :utc_datetime (1-second resolution), so identical calls in the same second
    # collide. The global unique index turned that into an insert failure.
    test "identical traces in two companies both insert", %{a: a, b: b} do
      occurred_at = DateTime.utc_now() |> DateTime.truncate(:second)

      insert = fn company_id, seq ->
        attrs = %{
          trace_type: "tool_call",
          tool_name: "read_file",
          tool_arguments: %{"path" => "/tmp/x"},
          status: "success",
          occurred_at: occurred_at,
          actor_type: "agent",
          company_id: company_id,
          sequence_number: seq
        }

        {hash, _} = ToolCallTrace.calculate_content_hash(attrs)

        attrs
        |> Map.put(:content_hash, hash)
        |> Map.put(:chain_hash, ToolCallTrace.calculate_chain_hash(hash, nil))
        |> then(&ToolCallTrace.changeset(%ToolCallTrace{}, &1))
        |> Repo.insert()
      end

      assert {:ok, _} = insert.(a.id, 1)
      assert {:ok, _} = insert.(b.id, 1)
    end

    # Deliberate: the trace suite treats duplicate-content_hash rejection as a
    # security property, so scoping the index to the tenant must not weaken it
    # inside one tenant.
    test "one company still cannot repeat an identical call within the same second", %{a: a} do
      occurred_at = DateTime.utc_now() |> DateTime.truncate(:second)

      insert = fn seq ->
        attrs = %{
          trace_type: "tool_call",
          tool_name: "read_file",
          tool_arguments: %{"path" => "/tmp/same"},
          status: "success",
          occurred_at: occurred_at,
          actor_type: "agent",
          company_id: a.id,
          sequence_number: seq
        }

        {hash, _} = ToolCallTrace.calculate_content_hash(attrs)

        attrs
        |> Map.put(:content_hash, hash)
        |> Map.put(:chain_hash, ToolCallTrace.calculate_chain_hash(hash, nil))
        |> then(&ToolCallTrace.changeset(%ToolCallTrace{}, &1))
        |> Repo.insert()
      end

      assert {:ok, _} = insert.(1)
      assert {:error, %Ecto.Changeset{}} = insert.(2)
    end
  end
end
