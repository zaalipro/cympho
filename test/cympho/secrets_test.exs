defmodule Cympho.SecretsTest do
  use Cympho.DataCase, async: true

  import Ecto.Query

  alias Cympho.Agents
  alias Cympho.Companies
  alias Cympho.Repo
  alias Cympho.Secrets
  alias Cympho.Secrets.EncryptedStorage
  alias Cympho.Secrets.Secret

  describe "rotation inventory" do
    test "classifies active secrets without decrypting values" do
      {:ok, company} =
        Companies.create_company(%{
          name: "Rotation Corp",
          slug: "rotation-corp-#{System.unique_integer([:positive])}"
        })

      now = ~U[2026-06-10 12:00:00Z]

      fresh = create_secret!(company.id, "FRESH_KEY", "fresh-secret")
      due = create_secret!(company.id, "DUE_KEY", "due-secret")
      overdue = create_secret!(company.id, "OVERDUE_KEY", "overdue-secret")

      set_inserted_at!(fresh, days_before(now, 30))
      set_inserted_at!(due, days_before(now, 120))
      set_inserted_at!(overdue, days_before(now, 220))

      entries = Secrets.rotation_inventory(company.id, now: now)
      by_key = Map.new(entries, &{&1.key, &1})

      assert by_key["FRESH_KEY"].status == :fresh
      assert by_key["FRESH_KEY"].age_days == 30
      assert by_key["FRESH_KEY"].action_label == "Current"

      assert by_key["DUE_KEY"].status == :due_soon
      assert by_key["DUE_KEY"].action_label == "Plan rotation"

      assert by_key["OVERDUE_KEY"].status == :overdue
      assert by_key["OVERDUE_KEY"].action_label == "Rotate now"

      refute inspect(entries) =~ "fresh-secret"
      refute inspect(entries) =~ "due-secret"
      refute inspect(entries) =~ "overdue-secret"
    end

    test "summarizes rotation posture by status and scope" do
      {:ok, company} =
        Companies.create_company(%{
          name: "Rotation Summary Corp",
          slug: "rotation-summary-#{System.unique_integer([:positive])}"
        })

      now = ~U[2026-06-10 12:00:00Z]
      fresh = create_secret!(company.id, "FRESH_KEY", "fresh-secret", scope: "company")
      due = create_secret!(company.id, "DUE_KEY", "due-secret", scope: "company")
      overdue = create_secret!(company.id, "OVERDUE_KEY", "overdue-secret", scope: "agent")

      set_inserted_at!(fresh, days_before(now, 10))
      set_inserted_at!(due, days_before(now, 100))
      set_inserted_at!(overdue, days_before(now, 200))

      assert %{
               total: 3,
               fresh: 1,
               due_soon: 1,
               overdue: 1,
               needs_rotation: 2,
               by_scope: %{"agent" => 1, "company" => 2}
             } = Secrets.rotation_summary(company.id, now: now)
    end

    test "metadata edits do not reset active version rotation age" do
      {:ok, company} =
        Companies.create_company(%{
          name: "Rotation Metadata Corp",
          slug: "rotation-metadata-#{System.unique_integer([:positive])}"
        })

      now = ~U[2026-06-10 12:00:00Z]
      secret = create_secret!(company.id, "DUE_KEY", "due-secret")
      inserted_at = days_before(now, 120)
      updated_at = days_before(now, 1)

      set_inserted_at!(secret, inserted_at)

      Repo.update_all(from(s in Secret, where: s.id == ^secret.id),
        set: [description: "recent metadata edit", updated_at: updated_at]
      )

      entry =
        company.id
        |> Secrets.rotation_inventory(now: now)
        |> Enum.find(&(&1.key == "DUE_KEY"))

      assert entry.status == :due_soon
      assert entry.age_days == 120
      assert entry.rotated_at == inserted_at
    end
  end

  describe "agent secret scoping" do
    test "foreign agent-scoped secret with the same key does not appear" do
      {:ok, company_a} =
        Companies.create_company(%{
          name: "Secrets A",
          slug: "secrets-a-#{System.unique_integer([:positive])}"
        })

      {:ok, company_b} =
        Companies.create_company(%{
          name: "Secrets B",
          slug: "secrets-b-#{System.unique_integer([:positive])}"
        })

      {:ok, agent_a} = create_agent!(company_a.id, "Agent A")
      {:ok, agent_b} = create_agent!(company_b.id, "Agent B")

      {:ok, _} =
        Secrets.create_secret(%{
          company_id: company_a.id,
          scope: "company",
          key: "ANTHROPIC_API_KEY",
          value: "company-a-key"
        })

      {:ok, _} =
        Secrets.create_secret(%{
          company_id: company_a.id,
          scope: "agent",
          scope_id: agent_a.id,
          key: "ANTHROPIC_API_KEY",
          value: "agent-a-key"
        })

      {:ok, foreign} =
        Secrets.create_secret(%{
          company_id: company_b.id,
          scope: "agent",
          scope_id: agent_b.id,
          key: "ANTHROPIC_API_KEY",
          value: "foreign-key"
        })

      assert {:error, changeset} =
               Secrets.create_secret(%{
                 company_id: company_b.id,
                 scope: "agent",
                 scope_id: agent_a.id,
                 key: "ANTHROPIC_API_KEY",
                 value: "cross-tenant"
               })

      assert %{scope_id: ["is not in this company"]} = errors_on(changeset)

      {:ok, encrypted} = EncryptedStorage.encrypt("rogue-key")

      {:ok, rogue} =
        %Secret{}
        |> Ecto.Changeset.change(%{
          company_id: company_b.id,
          scope: "agent",
          scope_id: agent_a.id,
          key: "ANTHROPIC_API_KEY",
          encrypted_value: encrypted,
          version: 1,
          is_active: true
        })
        |> Repo.insert()

      secrets = Secrets.list_secrets_for_agent(agent_a.id)
      refute Enum.any?(secrets, &(&1.id == foreign.id))
      refute Enum.any?(secrets, &(&1.id == rogue.id))
      assert Secrets.resolve_env_for_agent(agent_a.id)["ANTHROPIC_API_KEY"] == "agent-a-key"
    end

    test "agent-scoped values override company-scoped values" do
      {:ok, company} =
        Companies.create_company(%{
          name: "Secrets Merge",
          slug: "secrets-merge-#{System.unique_integer([:positive])}"
        })

      {:ok, agent} = create_agent!(company.id, "Merge Agent")

      {:ok, _} =
        Secrets.create_secret(%{
          company_id: company.id,
          scope: "company",
          key: "ANTHROPIC_API_KEY",
          value: "company-key"
        })

      {:ok, _} =
        Secrets.create_secret(%{
          company_id: company.id,
          scope: "agent",
          scope_id: agent.id,
          key: "ANTHROPIC_API_KEY",
          value: "agent-key"
        })

      assert Secrets.resolve_env_for_agent(agent.id)["ANTHROPIC_API_KEY"] == "agent-key"
    end

    test "update_secret treats blank values as unchanged and rotate requires a value" do
      {:ok, company} =
        Companies.create_company(%{
          name: "Secrets Rotate",
          slug: "secrets-rotate-#{System.unique_integer([:positive])}"
        })

      secret = create_secret!(company.id, "API_KEY", "original-secret")

      {:ok, updated} = Secrets.update_secret(secret, %{description: "meta", value: "   "})
      assert updated.description == "meta"
      assert {:ok, "original-secret"} = Secrets.get_secret_value(updated.id)

      assert {:error, :value_required} = Secrets.rotate_secret(secret, "  ")
      assert {:error, :value_required} = Secrets.rotate_secret(secret, nil)
    end
  end

  defp create_secret!(company_id, key, value, opts \\ []) do
    scope = Keyword.get(opts, :scope, "company")

    attrs = %{
      company_id: company_id,
      scope: scope,
      scope_id: Keyword.get_lazy(opts, :scope_id, fn -> scope_id(company_id, scope) end),
      key: key,
      value: value,
      description: "#{key} credential"
    }

    {:ok, secret} = Secrets.create_secret(attrs)
    secret
  end

  defp scope_id(_company_id, "company"), do: nil
  defp scope_id(_company_id, "instance"), do: nil

  defp scope_id(company_id, "agent") do
    {:ok, agent} = create_agent!(company_id, "Secret Agent")
    agent.id
  end

  defp scope_id(_company_id, _scope), do: Ecto.UUID.generate()

  defp create_agent!(company_id, name) do
    Agents.create_agent(%{
      company_id: company_id,
      name: "#{name} #{System.unique_integer([:positive])}",
      role: :engineer,
      status: :idle,
      adapter: :process,
      config: %{"command" => "echo"}
    })
  end

  defp days_before(now, days), do: DateTime.add(now, -days * 86_400, :second)

  defp set_inserted_at!(%Secret{} = secret, inserted_at) do
    Repo.update_all(from(s in Secret, where: s.id == ^secret.id),
      set: [inserted_at: inserted_at]
    )

    Repo.reload!(secret)
  end
end
