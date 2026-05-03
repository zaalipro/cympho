alias Cympho.Companies

case Companies.list_companies() do
  [] ->
    {:ok, %{company: company, agents: agents, first_issue: issue}} =
      Companies.create_autonomous_company(%{
        name: "Cympho Labs",
        goal_title: "Build and operate an autonomous software company",
        issue_prefix: "CYM",
        engineer_count: 3,
        adapter: :codex
      })

    IO.puts("""
    Seeded autonomous company:
      Company: #{company.name}
      Agents: #{Enum.map_join(agents, ", ", & &1.name)}
      First issue: #{issue.identifier} #{issue.title}
    """)

  companies ->
    IO.puts("Skipping seeds; #{length(companies)} companies already exist.")
end
