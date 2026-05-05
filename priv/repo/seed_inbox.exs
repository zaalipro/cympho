alias Cympho.{Agents, Companies, Issues, Repo}
alias Cympho.Inbox.InboxState

statuses = ~w(unread unread unread read read dismissed archived)

now = DateTime.utc_now() |> DateTime.truncate(:second)

companies = Companies.list_companies()

if companies == [] do
  IO.puts("No companies found. Run `mix run priv/repo/seeds.exs` first.")
  exit({:shutdown, 0})
end

{created, skipped} =
  Enum.reduce(companies, {0, 0}, fn company, {c, s} ->
    agents = Agents.list_agents_by_company(company.id)
    issues = Issues.list_issues(%{company_id: company.id}) |> Enum.take(40)

    if agents == [] or issues == [] do
      IO.puts("  [#{company.name}] skipping — agents=#{length(agents)} issues=#{length(issues)}")

      {c, s}
    else
      Enum.reduce(issues, {c, s}, fn issue, {c2, s2} ->
        # Pick 1–3 agents per issue with weighted preference for assignee/parent.
        priority_agent_ids =
          [issue.assignee_id, issue.created_by_agent_id]
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()

        random_agents =
          agents
          |> Enum.shuffle()
          |> Enum.take(:rand.uniform(3))
          |> Enum.map(& &1.id)

        target_agent_ids =
          (priority_agent_ids ++ random_agents)
          |> Enum.uniq()
          |> Enum.take(3)

        Enum.reduce(target_agent_ids, {c2, s2}, fn agent_id, {c3, s3} ->
          status = Enum.random(statuses)

          # Stagger inserted_at across the last few days so the dashboard ordering looks natural.
          inserted_at =
            now
            |> DateTime.add(-(:rand.uniform(72) * 3600), :second)
            |> DateTime.truncate(:second)

          read_at =
            if status in ["read", "dismissed", "archived"], do: inserted_at, else: nil

          dismissed_at = if status == "dismissed", do: inserted_at, else: nil
          archived_at = if status == "archived", do: inserted_at, else: nil

          attrs = %{
            issue_id: issue.id,
            agent_id: agent_id,
            status: status,
            read_at: read_at,
            dismissed_at: dismissed_at,
            archived_at: archived_at,
            inserted_at: inserted_at,
            updated_at: inserted_at
          }

          case Repo.insert(
                 InboxState.changeset(%InboxState{}, attrs)
                 |> Ecto.Changeset.force_change(:inserted_at, inserted_at)
                 |> Ecto.Changeset.force_change(:updated_at, inserted_at),
                 on_conflict: :nothing,
                 conflict_target: [:issue_id, :agent_id]
               ) do
            {:ok, %{id: nil}} -> {c3, s3 + 1}
            {:ok, _} -> {c3 + 1, s3}
            {:error, _} -> {c3, s3 + 1}
          end
        end)
      end)
    end
  end)

IO.puts("Inbox seed complete: #{created} created, #{skipped} skipped (already existed).")
