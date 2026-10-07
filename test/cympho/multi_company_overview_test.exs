defmodule Cympho.MultiCompanyOverviewTest do
  use Cympho.DataCase, async: true

  alias Cympho.{Agents, Companies, Costs, Issues, MultiCompanyOverview, Repo, Users}
  alias Cympho.Finances.{BudgetPolicy, TokenUsage}
  alias Cympho.HeartbeatEngine.Run

  setup do
    unique = System.unique_integer([:positive])

    {:ok, user} =
      Users.create_user(%{
        email: "overview-#{unique}@example.test",
        password: "password1234",
        name: "Overview reader"
      })

    companies =
      for label <- ~w(A B C), into: %{} do
        {:ok, company} =
          Companies.create_company(%{
            name: "Overview #{label}",
            slug: "overview-#{String.downcase(label)}-#{unique}"
          })

        {label, company}
      end

    for label <- ~w(A B) do
      {:ok, _} =
        Companies.create_membership(%{
          user_id: user.id,
          company_id: companies[label].id,
          role: "viewer"
        })
    end

    %{user: user, companies: companies}
  end

  test "queries only memberships and counts running executions, review and blockers", %{
    user: user,
    companies: companies
  } do
    for {label, company} <- companies do
      {:ok, agent} =
        Agents.create_agent(%{company_id: company.id, name: "Agent #{label}", role: :engineer})

      for status <- [:in_review, :blocked, :in_progress] do
        {:ok, issue} =
          Issues.create_issue(%{
            company_id: company.id,
            title: "#{label} #{status}",
            status: status
          })

        if status == :in_progress do
          for run_status <- ~w(running queued pending completed failed) do
            Repo.insert!(%Run{
              company_id: company.id,
              agent_id: agent.id,
              issue_id: issue.id,
              status: run_status
            })
          end
        end
      end
    end

    results = MultiCompanyOverview.list_for_user(user.id)
    assert Enum.sort(Enum.map(results, & &1.company.name)) == ["Overview A", "Overview B"]
    assert Enum.all?(results, &(&1.running == 1 and &1.review == 1 and &1.blocked == 1))
    refute inspect(results) =~ companies["C"].id
    assert MultiCompanyOverview.list_for_user(nil) == []
    assert MultiCompanyOverview.list_for_user(Ecto.UUID.generate()) == []
  end

  test "reuses Costs spend and preserves comparable, scoped-only and unconfigured posture", %{
    user: user,
    companies: companies
  } do
    a = companies["A"]
    b = companies["B"]

    Repo.insert!(
      BudgetPolicy.changeset(%BudgetPolicy{}, %{
        company_id: a.id,
        scope: "company",
        budget_limit_usd: "100",
        period: "weekly"
      })
    )

    Repo.insert!(
      BudgetPolicy.changeset(%BudgetPolicy{}, %{
        company_id: b.id,
        scope: "project",
        scope_id: Ecto.UUID.generate(),
        budget_limit_usd: "20"
      })
    )

    Repo.insert!(%TokenUsage{
      company_id: a.id,
      cost_usd: Decimal.new("85"),
      total_tokens: 100,
      provider: "synthetic",
      model: "synthetic"
    })

    results = Map.new(MultiCompanyOverview.list_for_user(user.id), &{&1.company.id, &1.budget})
    expected = Costs.spend_posture(a.id, Costs.summary(a.id, 7).total_cost)
    assert results[a.id] == expected
    assert results[a.id].budget_status == :watch
    assert Decimal.eq?(results[a.id].budget_remaining, Decimal.new("15"))
    assert results[b.id].budget_configured
    refute results[b.id].budget_comparable
    assert results[b.id].budget_remaining == nil
    assert results[b.id].budget_limit == nil

    Repo.delete!(Companies.get_membership(user.id, b.id))
    Repo.delete_all(BudgetPolicy)
    [result] = MultiCompanyOverview.list_for_user(user.id)
    assert result.company.id == a.id
    refute result.budget.budget_configured
    assert result.budget.budget_remaining == nil
  end
end
