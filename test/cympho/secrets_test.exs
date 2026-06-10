defmodule Cympho.SecretsTest do
  use Cympho.DataCase, async: true

  import Ecto.Query

  alias Cympho.Companies
  alias Cympho.Repo
  alias Cympho.Secrets
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

  defp create_secret!(company_id, key, value, opts \\ []) do
    scope = Keyword.get(opts, :scope, "company")

    attrs = %{
      company_id: company_id,
      scope: scope,
      scope_id: scope_id(scope),
      key: key,
      value: value,
      description: "#{key} credential"
    }

    {:ok, secret} = Secrets.create_secret(attrs)
    secret
  end

  defp scope_id("company"), do: nil
  defp scope_id("instance"), do: nil
  defp scope_id(_scope), do: Ecto.UUID.generate()

  defp days_before(now, days), do: DateTime.add(now, -days * 86_400, :second)

  defp set_inserted_at!(%Secret{} = secret, inserted_at) do
    Repo.update_all(from(s in Secret, where: s.id == ^secret.id),
      set: [inserted_at: inserted_at]
    )

    Repo.reload!(secret)
  end
end
