defmodule Cympho.RuntimeCapacity do
  @moduledoc """
  Qualitative runtime pressure estimates for agent adapters.

  BEAM processes are cheap, but local adapter CLIs are not: each concurrent
  Codex/Claude/Cursor/process job can become a real OS process with its own
  memory footprint. These helpers keep that distinction visible in the UI.
  """

  @local_adapters ~w(claude_code codex cursor process)
  @gateway_adapters ~w(http openclaw)

  @type level :: :safe | :watch | :high

  @doc """
  Estimates pressure for one agent.
  """
  @spec agent(map(), non_neg_integer()) :: map()
  def agent(agent, running_runs \\ 0) do
    adapter = adapter_name(Map.get(agent, :adapter) || Map.get(agent, "adapter"))

    max_jobs =
      positive_int(
        Map.get(agent, :max_concurrent_jobs) || Map.get(agent, "max_concurrent_jobs"),
        1
      )

    runtime_type = runtime_type(adapter)
    local? = local_adapter?(adapter)
    score = pressure_score(adapter, max_jobs, running_runs)
    level = agent_level(adapter, max_jobs, running_runs, score)

    %{
      adapter: adapter,
      adapter_label: adapter_label(adapter),
      runtime_type: runtime_type,
      local_process?: local?,
      max_concurrent_jobs: max_jobs,
      running_runs: running_runs,
      score: score,
      level: level,
      label: level_label(level),
      summary: agent_summary(level, adapter, max_jobs, running_runs),
      hint: agent_hint(level, adapter),
      slot_label: slot_label(max_jobs, local?)
    }
  end

  @doc """
  Estimates company-wide runtime pressure from agents and active run counts.
  """
  @spec company([map()], map()) :: map()
  def company(agents, running_counts \\ %{}) do
    agent_caps =
      Enum.map(agents, fn agent ->
        agent(agent, running_count_for(agent, running_counts))
      end)

    total_slots = Enum.reduce(agent_caps, 0, &(&1.max_concurrent_jobs + &2))

    local_slots =
      agent_caps
      |> Enum.filter(& &1.local_process?)
      |> Enum.reduce(0, &(&1.max_concurrent_jobs + &2))

    gateway_slots = total_slots - local_slots
    running_runs = Enum.reduce(agent_caps, 0, &(&1.running_runs + &2))

    local_running =
      agent_caps |> Enum.filter(& &1.local_process?) |> Enum.reduce(0, &(&1.running_runs + &2))

    highest = highest_level(agent_caps)
    level = company_level(highest, local_slots, local_running, total_slots)

    %{
      level: level,
      label: level_label(level),
      summary: company_summary(level, total_slots, local_slots),
      hint: company_hint(level),
      total_agents: length(agent_caps),
      total_slots: total_slots,
      local_slots: local_slots,
      gateway_slots: gateway_slots,
      running_runs: running_runs,
      local_running: local_running,
      local_agent_count: Enum.count(agent_caps, & &1.local_process?),
      agent_pressure: agent_caps
    }
  end

  def local_adapter?(adapter), do: adapter_name(adapter) in @local_adapters
  def gateway_adapter?(adapter), do: adapter_name(adapter) in @gateway_adapters

  def runtime_type(adapter) do
    adapter = adapter_name(adapter)

    cond do
      adapter in @local_adapters -> "Local CLI/process"
      adapter in @gateway_adapters -> "Remote gateway"
      true -> "Unknown runtime"
    end
  end

  defp agent_level(adapter, max_jobs, running_runs, score) do
    cond do
      local_adapter?(adapter) and (max_jobs >= 6 or running_runs >= 4 or score >= 12) -> :high
      local_adapter?(adapter) and (max_jobs >= 3 or running_runs >= 2 or score >= 6) -> :watch
      gateway_adapter?(adapter) and (max_jobs >= 12 or running_runs >= 8) -> :watch
      true -> :safe
    end
  end

  defp company_level(:high, _local_slots, _local_running, _total_slots), do: :high

  defp company_level(_highest, local_slots, local_running, total_slots) do
    cond do
      local_slots >= 12 or local_running >= 6 -> :high
      local_slots >= 6 or local_running >= 3 or total_slots >= 24 -> :watch
      true -> :safe
    end
  end

  defp highest_level(agent_caps) do
    cond do
      Enum.any?(agent_caps, &(&1.level == :high)) -> :high
      Enum.any?(agent_caps, &(&1.level == :watch)) -> :watch
      true -> :safe
    end
  end

  defp pressure_score(adapter, max_jobs, running_runs) do
    weight =
      cond do
        adapter in ~w(claude_code codex cursor) -> 2
        adapter == "process" -> 2
        adapter in @gateway_adapters -> 1
        true -> 1
      end

    max_jobs * weight + running_runs * weight
  end

  defp agent_summary(:safe, _adapter, max_jobs, _running_runs),
    do: "#{max_jobs} configured slot#{plural(max_jobs)} should be light for this host."

  defp agent_summary(:watch, adapter, max_jobs, running_runs),
    do:
      "#{adapter_label(adapter)} can open #{max_jobs} slot#{plural(max_jobs)}; #{running_runs} currently running."

  defp agent_summary(:high, adapter, max_jobs, _running_runs),
    do: "#{adapter_label(adapter)} is configured for #{max_jobs} concurrent OS-backed jobs."

  defp agent_hint(:safe, adapter) do
    if local_adapter?(adapter) do
      "BEAM supervision stays light; memory pressure mostly comes from the spawned CLI."
    else
      "Most execution pressure is shifted to the remote gateway or service."
    end
  end

  defp agent_hint(:watch, adapter) do
    if local_adapter?(adapter) do
      "Watch RAM before increasing this agent. Local CLIs do not share BEAM's lightweight process model."
    else
      "Watch provider quotas, gateway latency, and remote concurrency limits."
    end
  end

  defp agent_hint(:high, _adapter),
    do:
      "Lower max jobs or move execution to a larger host before enabling broad autonomous fan-out."

  defp company_summary(:safe, total_slots, local_slots),
    do: "#{total_slots} total slots, #{local_slots} local CLI/process slots."

  defp company_summary(:watch, _total_slots, local_slots),
    do: "#{local_slots} local CLI/process slots can create noticeable RAM pressure."

  defp company_summary(:high, _total_slots, local_slots),
    do: "#{local_slots} local CLI/process slots can overload a small host."

  defp company_hint(:safe),
    do:
      "Cympho orchestration is lightweight; external adapter processes are the main capacity driver."

  defp company_hint(:watch),
    do: "Keep an eye on RAM and provider quotas before raising max concurrent jobs."

  defp company_hint(:high),
    do: "Reduce CLI-backed concurrency or run workers on a host sized for parallel agent CLIs."

  defp level_label(:safe), do: "Safe"
  defp level_label(:watch), do: "Watch"
  defp level_label(:high), do: "High pressure"

  defp slot_label(max_jobs, true), do: "#{max_jobs} local CLI slot#{plural(max_jobs)}"
  defp slot_label(max_jobs, false), do: "#{max_jobs} gateway slot#{plural(max_jobs)}"

  defp adapter_label(nil), do: "Unknown adapter"

  defp adapter_label(adapter) do
    adapter
    |> to_string()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp running_count_for(agent, counts) do
    id = Map.get(agent, :id) || Map.get(agent, "id")
    positive_int(Map.get(counts, id) || Map.get(counts, to_string(id)), 0)
  end

  defp adapter_name(nil), do: nil
  defp adapter_name(adapter), do: adapter |> to_string()

  defp positive_int(value, _fallback) when is_integer(value) and value > 0, do: value

  defp positive_int(value, fallback) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} when int > 0 -> int
      _ -> fallback
    end
  end

  defp positive_int(_value, fallback), do: fallback

  defp plural(1), do: ""
  defp plural(_), do: "s"
end
