defmodule Mix.Tasks.Cympho.Bootstrap do
  @shortdoc "Create an autonomous company with CEO, CTO, engineers, and seed issues"

  @moduledoc """
  Bootstraps a new autonomous company in one command.

  ## Usage

      mix cympho.bootstrap --company-name "TestCo" --mission "Build the best API" --engineers 3 --yes

  ## Options

    * `--company-name` - Name of the company (required)
    * `--mission` - Company mission / goal title (default: "Build and run the business autonomously")
    * `--engineers` - Number of engineer agents (default: 2)
    * `--prefix` - Issue prefix (default: "LLM")
    * `--adapter` - Agent adapter: claude_code, codex, cursor, http, openclaw, process (default: codex)
    * `--yes` - Skip confirmation prompts
  """

  use Mix.Task

  alias Cympho.Companies

  @switches [
    company_name: :string,
    mission: :string,
    engineers: :integer,
    prefix: :string,
    adapter: :string,
    yes: :boolean
  ]

  @aliases [
    n: :company_name,
    m: :mission,
    e: :engineers,
    p: :prefix,
    y: :yes
  ]

  @impl Mix.Task
  def run(args) do
    ensure_repo_started()

    {opts, _args, _invalid} = OptionParser.parse(args, switches: @switches, aliases: @aliases)

    company_name = opts[:company_name]
    mission = opts[:mission] || "Build and run the business autonomously"
    engineers = opts[:engineers] || 2
    prefix = opts[:prefix] || "LLM"
    adapter = (opts[:adapter] || "codex") |> String.to_atom()
    auto_yes = opts[:yes] || false

    unless company_name do
      Mix.shell().error("Error: --company-name is required.")

      Mix.shell().info(
        "\nUsage: mix cympho.bootstrap --company-name \"Name\" [--mission \"Goal\"] [--engineers N] [--yes]"
      )

      Mix.raise("Missing required option: --company-name")
    end

    engineers = max(0, engineers)

    if auto_yes do
      do_bootstrap(company_name, mission, engineers, prefix, adapter)
    else
      Mix.shell().info("""
      About to create:
        Company:    #{company_name}
        Mission:    #{mission}
        Engineers:  #{engineers}
        Prefix:     #{prefix}
        Adapter:    #{adapter}
      """)

      if Mix.shell().yes?("Proceed with bootstrap?") do
        do_bootstrap(company_name, mission, engineers, prefix, adapter)
      else
        Mix.shell().info("Aborted.")
      end
    end
  end

  defp do_bootstrap(name, mission, engineers, prefix, adapter) do
    Mix.shell().info("Bootstrapping #{name}...")

    attrs = %{
      name: name,
      goal_title: mission,
      engineer_count: engineers,
      issue_prefix: prefix,
      adapter: adapter
    }

    case Companies.create_autonomous_company(attrs) do
      {:ok, result} ->
        company = result.company
        project = result.project
        goal = result.goal
        agents = result.agents
        seed_issues = result.seed_issues

        Mix.shell().info("""

        ✓ Company created: #{company.name} (#{company.slug})
        ✓ Project: #{project.name} (#{project.prefix})
        ✓ Mission goal: #{goal.title}
        ✓ Agents: #{Enum.map_join(agents, ", ", &"#{&1.name} (#{&1.role})")}
        ✓ Seed issues: #{length(seed_issues)} issues queued

          #{Enum.map_join(seed_issues, "\n  ", &"#{&1.identifier} — #{&1.title}")}

        Done. Run `mix phx.server` and visit the app to start.
        """)

      {:error, reason} ->
        Mix.shell().error("Bootstrap failed: #{inspect(reason)}")
        Mix.raise("Bootstrap failed")
    end
  end

  defp ensure_repo_started do
    Mix.Task.run("app.start", [])
  end
end
