defmodule Mix.Tasks.Cympho.BenchmarkIdleAgents do
  use Mix.Task

  alias Cympho.Benchmarks.IdleAgents

  @shortdoc "Measure idle heartbeat scaling under MIX_ENV=test"

  @moduledoc """
  Runs the non-destructive idle-agent benchmark.

      MIX_ENV=test mix cympho.benchmark_idle_agents --agents 100 --duration-ms 15000

  Use `--mode delegated` for the default event-driven path and `--mode direct`
  for the legacy per-agent checkout path. The last stdout line is JSON; use
  `--json PATH` to also save a pretty-printed artifact.
  """

  @impl Mix.Task
  def run(args) do
    unless Mix.env() == :test do
      Mix.raise("cympho.benchmark_idle_agents only runs with MIX_ENV=test")
    end

    case IdleAgents.parse_options(args) do
      {:help, usage} ->
        Mix.shell().info(usage)

      {:error, message} ->
        Mix.raise("#{message}\n\n#{IdleAgents.usage()}")

      {:ok, options} ->
        Mix.Task.run("app.start")
        result = IdleAgents.run(options)

        if options.json do
          options.json |> Path.dirname() |> File.mkdir_p!()
          File.write!(options.json, Jason.encode!(result, pretty: true) <> "\n")
        end

        Mix.shell().info(IdleAgents.human_summary(result))
        IO.puts(Jason.encode!(result))
    end
  end
end
