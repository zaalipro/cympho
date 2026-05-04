alias Cympho.{Approvals, Repo}
alias Cympho.Approvals.Approval
alias Cympho.Agents.Agent
alias Cympho.Issues.Issue
alias Cympho.Companies
import Ecto.Query

[company | _] = Companies.list_companies()

agent_by_name = fn name ->
  Repo.one(from a in Agent, where: a.company_id == ^company.id and a.name == ^name)
end

ceo = agent_by_name.("CEO")
cto = agent_by_name.("CTO")
e1 = agent_by_name.("Engineer 1")
e2 = agent_by_name.("Engineer 2")
e3 = agent_by_name.("Engineer 3")

issues =
  Repo.all(
    from i in Issue,
      where: i.company_id == ^company.id and not is_nil(i.identifier),
      order_by: [asc: i.issue_number],
      limit: 5
  )

[i1, i2, i3, i4 | _] = issues ++ List.duplicate(List.first(issues), 4)

samples = [
  %{
    type: "production_deploy",
    requested_by_agent_id: cto.id,
    payload: %{
      "summary" => "Deploy v1.4.2 to production",
      "release_notes" => "State-machine fix, project repo URLs, agent reports-to."
    },
    issue_ids: [i1.id, i2.id],
    status: :pending,
    age_hours: 0
  },
  %{
    type: "external_api_access",
    requested_by_agent_id: e1.id,
    payload: %{
      "summary" => "Allow agent to call OpenAI Embeddings API",
      "scope" => "embeddings.read",
      "rationale" => "Implementing semantic similarity for issue de-duplication"
    },
    issue_ids: [i1.id],
    status: :pending,
    age_hours: 2
  },
  %{
    type: "budget_increase",
    requested_by_agent_id: ceo.id,
    payload: %{
      "summary" => "Raise monthly engineering budget from $4,000 → $6,000",
      "delta_cents" => 200_000,
      "duration" => "1 quarter"
    },
    issue_ids: [],
    status: :pending,
    age_hours: 6
  },
  %{
    type: "agent_hire",
    requested_by_agent_id: cto.id,
    payload: %{
      "summary" => "Hire a second QA engineer to cover release work",
      "role" => "engineer",
      "name" => "Dia QA Engineer Jr"
    },
    issue_ids: [],
    status: :approved,
    age_hours: 26
  },
  %{
    type: "dangerous_runtime_action",
    requested_by_agent_id: e2.id,
    payload: %{
      "summary" => "Run database migration on production",
      "command" => "mix ecto.migrate",
      "risk" => "schema change to large table"
    },
    issue_ids: [i3.id],
    status: :approved,
    age_hours: 30
  },
  %{
    type: "data_export",
    requested_by_agent_id: e3.id,
    payload: %{
      "summary" => "Export all customer support transcripts",
      "scope" => "support.transcripts",
      "destination" => "s3://exports-staging/"
    },
    issue_ids: [i4.id],
    status: :denied,
    resolution_reason: "PII review still outstanding — re-request after redaction.",
    age_hours: 50
  },
  %{
    type: "external_api_access",
    requested_by_agent_id: e1.id,
    payload: %{
      "summary" => "Call internal Slack webhook on issue completion",
      "scope" => "slack.write"
    },
    issue_ids: [i2.id],
    status: :cancelled,
    age_hours: 72
  }
]

inserted =
  Enum.map(samples, fn sample ->
    {:ok, approval} =
      Approvals.create_approval(%{
        type: sample.type,
        requested_by_agent_id: sample.requested_by_agent_id,
        payload: sample.payload,
        issue_ids: sample.issue_ids
      })

    backdated = DateTime.utc_now() |> DateTime.add(-sample.age_hours * 3600, :second) |> DateTime.truncate(:second)

    {:ok, approval} =
      approval
      |> Ecto.Changeset.change(inserted_at: backdated, updated_at: backdated)
      |> Repo.update()

    case sample.status do
      :pending ->
        approval

      :cancelled ->
        {:ok, cancelled} = Approvals.cancel_approval(approval.id)
        cancelled

      status when status in [:approved, :denied] ->
        {:ok, resolved} =
          Approvals.resolve_approval(approval.id, status, %{
            resolution_reason: sample[:resolution_reason]
          })

        resolved
    end
  end)

IO.puts("Seeded #{length(inserted)} approvals for #{company.name}.")

Enum.each(inserted, fn a ->
  IO.puts("  - #{a.status |> to_string() |> String.pad_trailing(10)} #{a.type}")
end)
