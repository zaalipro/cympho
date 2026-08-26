defmodule Mix.Tasks.Cympho.Doctor do
  @shortdoc "Run non-destructive Cympho operator diagnostics"

  @moduledoc """
  Checks the source checkout, effective runtime configuration, PostgreSQL,
  migrations, endpoint configuration, attachment storage, BEAM resources, and
  aggregate adapter health without starting the Cympho application supervisor.

      mix cympho.doctor
      mix cympho.doctor --json
      mix cympho.doctor --probe-endpoint --strict

  `--probe-endpoint` performs only a bounded TCP connection to the configured
  listener. It does not claim application or database readiness. `--strict`
  returns a failing exit status for warnings as well as failures.
  """

  use Mix.Task

  alias Cympho.Diagnostics

  @switches [json: :boolean, strict: :boolean, probe_endpoint: :boolean]

  @impl Mix.Task
  def run(args) do
    {report, opts} = run_with(args)

    exit_code = Diagnostics.exit_code(report, opts[:strict] == true)
    if exit_code != 0, do: System.at_exit(fn _ -> exit({:shutdown, exit_code}) end)

    report
  end

  @doc false
  def run_with(args, diagnostic_opts \\ []) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)

    if positional != [] or invalid != [] do
      Mix.raise(
        "Invalid arguments. Use: mix cympho.doctor [--json] [--strict] [--probe-endpoint]"
      )
    end

    previous_level = Logger.level()
    Logger.configure(level: :emergency)

    try do
      report =
        diagnostic_opts
        |> Keyword.put(:probe_endpoint, opts[:probe_endpoint] == true)
        |> Diagnostics.run()

      if opts[:json] do
        IO.puts(Jason.encode!(report))
      else
        print_human(report)
      end

      {report, opts}
    after
      Logger.configure(level: previous_level)
    end
  end

  @doc false
  def print_human(report) do
    Mix.shell().info(
      "Cympho doctor #{report.application.version} (#{report.application.environment})"
    )

    Enum.each(report.checks, fn check ->
      Mix.shell().info("#{icon(check.status)} [#{check.category}] #{check.id}: #{check.message}")

      if check.status != :pass and check.repair do
        Mix.shell().info("    Repair: #{check.repair}")
      end
    end)

    summary = report.summary

    Mix.shell().info(
      "Summary: #{summary.passed} passed, #{summary.warned} warnings, #{summary.failed} failed"
    )
  end

  defp icon(:pass), do: "PASS"
  defp icon(:warn), do: "WARN"
  defp icon(:fail), do: "FAIL"
end
