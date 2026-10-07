defmodule Cympho.MultiCompanyOverview do
  @moduledoc "Read-only operational summaries for a user's current memberships."

  import Ecto.Query

  alias Cympho.{Companies, Costs, Repo}
  alias Cympho.Companies.CompanyMembership
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.Issues.Issue

  def list_for_user(user_id) when is_binary(user_id) do
    runs =
      from(r in Run,
        join: m in CompanyMembership,
        on: m.company_id == r.company_id and m.user_id == ^user_id,
        where: r.status == "running",
        group_by: r.company_id,
        select: {r.company_id, count(r.id)}
      )
      |> Repo.all()
      |> Map.new()

    issues =
      from(i in Issue,
        join: m in CompanyMembership,
        on: m.company_id == i.company_id and m.user_id == ^user_id,
        where: i.status in [:in_review, :blocked],
        group_by: [i.company_id, i.status],
        select: {{i.company_id, i.status}, count(i.id)}
      )
      |> Repo.all()
      |> Map.new()

    Companies.list_memberships_for_user(user_id)
    |> Enum.map(fn %{company: company} ->
      period = Costs.spend_period(company.id)
      spend = Costs.summary(company.id, period.days)

      %{
        company: %{id: company.id, name: company.name},
        running: Map.get(runs, company.id, 0),
        review: Map.get(issues, {company.id, :in_review}, 0),
        blocked: Map.get(issues, {company.id, :blocked}, 0),
        budget: Costs.spend_posture(company.id, spend.total_cost),
        has_unpriced_usage?: spend.has_unpriced_usage?
      }
    end)
  end

  def list_for_user(_user_id), do: []
end
