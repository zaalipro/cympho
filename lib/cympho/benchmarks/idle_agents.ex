defmodule Cympho.Benchmarks.IdleAgents do
  @moduledoc """
  Non-destructive benchmark for periodic heartbeats from idle agents.

  The benchmark is intentionally restricted to the test environment. It owns a
  shared SQL Sandbox connection, so its company and agents are rolled back even
  when the run raises or is interrupted. This module reports observations; it
  does not enforce machine-dependent performance thresholds.
  """

  alias Cympho.AgentHeartbeat
  alias Cympho.Agents.Agent
  alias Cympho.Companies.Company
  alias Cympho.Repo

  @heartbeat_interval_ms 5_000
  @query_event [:cympho, :repo, :query]
  @default_options %{
    agents: 100,
    duration_ms: 15_000,
    sample_ms: 1_000,
    mode: :delegated,
    json: nil
  }

  @switches [
    agents: :integer,
    duration_ms: :integer,
    sample_ms: :integer,
    mode: :string,
    json: :string,
    help: :boolean
  ]

  @type options :: %{
          agents: pos_integer(),
          duration_ms: pos_integer(),
          sample_ms: pos_integer(),
          mode: :delegated | :direct,
          json: String.t() | nil
        }

  @doc "Parses and validates command-line options without starting the benchmark."
  @spec parse_options([String.t()]) ::
          {:ok, options()} | {:help, String.t()} | {:error, String.t()}
  def parse_options(args) do
    {parsed, positional, invalid} = OptionParser.parse(args, strict: @switches)

    cond do
      parsed[:help] ->
        {:help, usage()}

      invalid != [] ->
        {:error, "invalid options: #{inspect(invalid)}"}

      positional != [] ->
        {:error, "unexpected positional arguments: #{Enum.join(positional, " ")}"}

      true ->
        parsed
        |> Enum.into(@default_options)
        |> normalize_mode()
        |> validate_options()
    end
  end

  @doc "Runs a benchmark after the application has been started under MIX_ENV=test."
  @spec run(options()) :: map()
  def run(options) do
    ensure_test_environment!()

    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    previous_heartbeat_config = Application.get_env(:cympho, :agent_heartbeat)

    try do
      configure_mode(options.mode)
      agents = create_fixtures(options.agents)
      workers = start_workers(agents)

      try do
        with_query_probe(fn probe ->
          # Legacy direct workers deliberately use a 60s first timer. Prime one
          # periodic tick so the measured window uses the fixture's 5s interval.
          # In delegated mode this is a DB-free no-op, as expected for the
          # default event-driven implementation.
          prime_workers(workers)
          reset_query_probe(probe)

          started_at = DateTime.utc_now()
          started_mono = System.monotonic_time(:millisecond)
          samples = observe(workers, options.duration_ms, options.sample_ms, started_mono)
          finished_mono = System.monotonic_time(:millisecond)
          elapsed_ms = max(finished_mono - started_mono, 1)

          build_result(options, workers, samples, query_metrics(probe), started_at, elapsed_ms)
        end)
      after
        stop_workers(workers)
      end
    after
      restore_heartbeat_config(previous_heartbeat_config)
      Ecto.Adapters.SQL.Sandbox.stop_owner(owner)
    end
  end

  @doc "Renders a compact human-readable view of a benchmark result."
  @spec human_summary(map()) :: String.t()
  def human_summary(result) do
    baseline = List.first(result.samples)
    peak_total = Enum.max(Enum.map(result.samples, & &1.beam_memory_total_bytes))
    peak_processes = Enum.max(Enum.map(result.samples, & &1.beam_process_count))
    peak_worker_memory = Enum.max(Enum.map(result.samples, & &1.heartbeat_memory_bytes))
    final = List.last(result.samples)

    """
    Cympho idle-agent benchmark (observational; no pass/fail threshold)
      mode / agents:       #{result.config.mode} / #{result.config.agents}
      observed:            #{format_duration(result.elapsed_ms)} at #{result.config.heartbeat_interval_ms}ms heartbeats
      DB queries:          #{result.database.query_count} (#{format_number(result.database.queries_per_second)} qps)
      DB query time:       #{format_number(result.database.query_time_ms)} ms total
      BEAM total memory:   #{format_bytes(baseline.beam_memory_total_bytes)} baseline, #{format_bytes(peak_total)} peak
      process memory:      #{format_bytes(baseline.beam_memory_processes_bytes)} baseline, #{format_bytes(final.beam_memory_processes_bytes)} final
      heartbeat memory:    #{format_bytes(peak_worker_memory)} peak across benchmark workers
      BEAM processes:      #{baseline.beam_process_count} baseline, #{peak_processes} peak
      workers / timers:    #{result.correctness.workers_alive}/#{result.config.agents} alive, #{final.heartbeat_timer_count} active timers
    """
    |> String.trim_trailing()
  end

  @doc false
  def usage do
    """
    MIX_ENV=test mix cympho.benchmark_idle_agents [options]

      --agents N          idle agents to create (default: 100)
      --duration-ms MS    observation window (default: 15000)
      --sample-ms MS      BEAM sample interval (default: 1000)
      --mode MODE         delegated (default/event-driven) or direct (legacy)
      --json PATH         also write pretty JSON to PATH
      --help              show this help
    """
  end

  @doc false
  def handle_repo_query(_event, measurements, _metadata, table) do
    :ets.update_counter(table, :query_count, {2, 1}, {:query_count, 0})

    query_time =
      measurements
      |> Map.get(:query_time, 0)
      |> System.convert_time_unit(:native, :microsecond)

    :ets.update_counter(
      table,
      :query_time_microseconds,
      {2, query_time},
      {:query_time_microseconds, 0}
    )
  end

  defp normalize_mode(options) do
    case options.mode do
      :delegated -> options
      :direct -> options
      "delegated" -> %{options | mode: :delegated}
      "direct" -> %{options | mode: :direct}
      other -> Map.put(options, :mode, other)
    end
  end

  defp validate_options(options) do
    cond do
      not is_integer(options.agents) or options.agents < 1 ->
        {:error, "--agents must be a positive integer"}

      not is_integer(options.duration_ms) or options.duration_ms < 1 ->
        {:error, "--duration-ms must be a positive integer"}

      not is_integer(options.sample_ms) or options.sample_ms < 1 ->
        {:error, "--sample-ms must be a positive integer"}

      options.mode not in [:delegated, :direct] ->
        {:error, "--mode must be delegated or direct"}

      true ->
        {:ok, options}
    end
  end

  defp ensure_test_environment! do
    unless Application.get_env(:cympho, :env) == :test do
      raise "idle-agent benchmark requires MIX_ENV=test"
    end
  end

  defp configure_mode(mode) do
    current = Application.get_env(:cympho, :agent_heartbeat, [])

    Application.put_env(
      :cympho,
      :agent_heartbeat,
      Keyword.put(current, :delegate_to_dispatcher, mode == :delegated)
    )
  end

  defp restore_heartbeat_config(nil), do: Application.delete_env(:cympho, :agent_heartbeat)

  defp restore_heartbeat_config(config),
    do: Application.put_env(:cympho, :agent_heartbeat, config)

  defp create_fixtures(agent_count) do
    nonce = System.unique_integer([:positive, :monotonic])
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    company =
      %Company{}
      |> Company.changeset(%{
        name: "Idle benchmark #{nonce}",
        slug: "idle-benchmark-#{nonce}",
        issue_prefix: "IB#{rem(nonce, 10_000)}"
      })
      |> Repo.insert!()

    Enum.map(1..agent_count, fn index ->
      %Agent{}
      |> Agent.changeset(%{
        name: "Idle benchmark agent #{index}",
        url_key: "idle-benchmark-#{nonce}-#{index}",
        role: :engineer,
        status: :idle,
        adapter: :process,
        company_id: company.id,
        heartbeat_config: %{"interval_ms" => @heartbeat_interval_ms},
        last_heartbeat_at: now
      })
      |> Repo.insert!()
    end)
  end

  defp with_query_probe(fun) do
    table = :ets.new(__MODULE__, [:set, :public])
    handler_id = {__MODULE__, self(), make_ref()}
    :ok = :telemetry.attach(handler_id, @query_event, &__MODULE__.handle_repo_query/4, table)

    try do
      fun.(table)
    after
      :telemetry.detach(handler_id)
      :ets.delete(table)
    end
  end

  # Start directly through the worker's public start_link/1 rather than the
  # production DynamicSupervisor, whose max_children=500 would prevent the
  # documented 1,000-idle-agent workload. Registry uniqueness and all actual
  # heartbeat behaviour remain unchanged.
  defp start_workers(agents) do
    Enum.reduce_while(agents, [], fn agent, started ->
      case AgentHeartbeat.start_link(agent_id: agent.id) do
        {:ok, pid} ->
          Process.unlink(pid)
          {:cont, [{agent.id, pid} | started]}

        error ->
          stop_workers(started)
          raise "could not start heartbeat for #{agent.id}: #{inspect(error)}"
      end
    end)
    |> Enum.reverse()
  end

  defp prime_workers(workers) do
    Enum.each(workers, fn {_agent_id, pid} -> send(pid, {:heartbeat, :timer}) end)

    Enum.each(workers, fn {agent_id, _pid} ->
      case AgentHeartbeat.status(agent_id) do
        {:ok, :idle} -> :ok
        other -> raise "heartbeat prime failed for #{agent_id}: #{inspect(other)}"
      end
    end)
  end

  defp reset_query_probe(table) do
    :ets.insert(table, [{:query_count, 0}, {:query_time_microseconds, 0}])
  end

  defp query_metrics(table) do
    %{
      query_count: lookup_counter(table, :query_count),
      query_time_microseconds: lookup_counter(table, :query_time_microseconds)
    }
  end

  defp lookup_counter(table, key) do
    case :ets.lookup(table, key) do
      [{^key, value}] -> value
      [] -> 0
    end
  end

  defp observe(workers, duration_ms, sample_ms, started_mono) do
    deadline = started_mono + duration_ms
    do_observe(workers, sample_ms, started_mono, deadline, [])
  end

  defp do_observe(workers, sample_ms, started_mono, deadline, samples) do
    now = System.monotonic_time(:millisecond)
    sample = sample(workers, max(now - started_mono, 0))
    samples = [sample | samples]
    remaining = deadline - now

    if remaining <= 0 do
      Enum.reverse(samples)
    else
      Process.sleep(min(sample_ms, remaining))
      do_observe(workers, sample_ms, started_mono, deadline, samples)
    end
  end

  defp sample(workers, elapsed_ms) do
    memory = :erlang.memory()

    {workers_alive, heartbeat_memory, timer_count} =
      Enum.reduce(workers, {0, 0, 0}, fn {_agent_id, pid}, {alive, bytes, timers} ->
        if Process.alive?(pid) do
          process_bytes = process_memory(pid)
          active_timer = if active_heartbeat_timer?(pid), do: 1, else: 0
          {alive + 1, bytes + process_bytes, timers + active_timer}
        else
          {alive, bytes, timers}
        end
      end)

    %{
      elapsed_ms: elapsed_ms,
      beam_memory_total_bytes: memory[:total],
      beam_memory_processes_bytes: memory[:processes],
      beam_memory_processes_used_bytes: memory[:processes_used],
      beam_process_count: :erlang.system_info(:process_count),
      beam_reductions: :erlang.statistics(:reductions) |> elem(0),
      heartbeat_workers_alive: workers_alive,
      heartbeat_memory_bytes: heartbeat_memory,
      heartbeat_timer_count: timer_count
    }
  end

  defp process_memory(pid) do
    case Process.info(pid, :memory) do
      {:memory, bytes} -> bytes
      nil -> 0
    end
  end

  defp active_heartbeat_timer?(pid) do
    case :sys.get_state(pid, 1_000) do
      %{timer_ref: timer_ref} when is_reference(timer_ref) ->
        is_integer(Process.read_timer(timer_ref))

      _ ->
        false
    end
  catch
    :exit, _reason -> false
  end

  defp build_result(options, workers, samples, query, started_at, elapsed_ms) do
    final_sample = List.last(samples)
    query_time_ms = query.query_time_microseconds / 1_000

    %{
      schema_version: 1,
      benchmark: "cympho_idle_agents",
      started_at: DateTime.to_iso8601(started_at),
      elapsed_ms: elapsed_ms,
      config: %{
        agents: options.agents,
        duration_ms: options.duration_ms,
        sample_ms: options.sample_ms,
        heartbeat_interval_ms: @heartbeat_interval_ms,
        mode: Atom.to_string(options.mode)
      },
      runtime: %{
        elixir: System.version(),
        otp_release: List.to_string(:erlang.system_info(:otp_release)),
        schedulers_online: :erlang.system_info(:schedulers_online)
      },
      database: %{
        query_count: query.query_count,
        query_time_ms: Float.round(query_time_ms, 3),
        queries_per_second: Float.round(query.query_count * 1_000 / elapsed_ms, 3)
      },
      correctness: %{
        workers_started: length(workers),
        workers_alive: final_sample.heartbeat_workers_alive,
        workers_idle: count_idle_workers(workers)
      },
      samples: samples
    }
  end

  defp count_idle_workers(workers) do
    Enum.count(workers, fn {agent_id, _pid} -> AgentHeartbeat.status(agent_id) == {:ok, :idle} end)
  end

  defp stop_workers(workers) do
    Enum.each(workers, fn {agent_id, pid} ->
      case AgentHeartbeat.stop_for_agent(agent_id) do
        :ok -> :ok
        _ -> if Process.alive?(pid), do: Process.exit(pid, :kill)
      end
    end)
  end

  defp format_duration(milliseconds), do: "#{format_number(milliseconds / 1_000)}s"

  defp format_bytes(bytes) when bytes < 1_024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1_048_576, do: "#{format_number(bytes / 1_024)} KiB"
  defp format_bytes(bytes), do: "#{format_number(bytes / 1_048_576)} MiB"

  defp format_number(number) when is_integer(number), do: Integer.to_string(number)
  defp format_number(number), do: :erlang.float_to_binary(number / 1, decimals: 2)
end
