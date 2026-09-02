defmodule Cympho.Benchmarks.ComparativeArtifact do
  @moduledoc false

  require Record
  Record.defrecordp(:file_info, Record.extract(:file_info, from_lib: "kernel/include/file.hrl"))

  @schema_name "cympho.paperclip.low-vps-comparison"
  @schema_version 1
  @max_manifest_bytes 2 * 1024 * 1024
  @max_raw_artifact_bytes 64 * 1024 * 1024
  @max_numeric_metric 1.0e18
  @measurement_tolerance 1.05
  @products ~w(cympho paperclip)
  @raw_artifact_kinds ~w(samples events database)
  @root_keys ~w(schema schema_version suite_id generated_at claim_eligible products host database protocol workload_cells)
  @host_keys ~w(os kernel architecture cgroup limits)
  @cgroup_keys ~w(version controllers)
  @limit_keys ~w(cpu_cores memory_max_bytes swap_max_bytes pids_max)
  @database_keys ~w(engine version config_sha256 pool_size limits)
  @protocol_keys ~w(runner_sha256 helper_sha256 duration_ms warmup_ms repetition_order app_limits)
  @product_keys ~w(revision dirty runtime_config_sha256 database_config_sha256 runner_sha256 app_cgroup_id database_cgroup_id app_limits database_limits)
  @cell_keys ~w(id workload agent_count active_concurrency dataset_sha256 scenario_sha256 scenario products)
  @product_result_keys ~w(repetitions)
  @trial_keys ~w(trial_id metrics correctness raw_artifacts)
  @metric_keys ~w(app database children operation_count throughput_per_second p95_latency_ms)
  @resource_metric_keys ~w(rss_peak_bytes cpu_seconds)
  @database_metric_keys ~w(rss_peak_bytes cpu_seconds query_count queries_per_second)
  @correctness_keys ~w(pass lost duplicate stranded oom_events recovery_failures restart_count applied_unique_wakes recovered completed)
  @idle_scenario_keys ~w(kind runnable_work)
  @active_scenario_keys ~w(kind total_operations)
  @wake_scenario_keys ~w(kind pattern unique_wakes repeated_deliveries)
  @restart_scenario_keys ~w(kind restart_count running_at_restart)
  @raw_artifact_keys ~w(kind path sha256)
  @required_cells %{
    "idle-100" => %{workload: "idle", agents: 100, concurrency: 0},
    "idle-500" => %{workload: "idle", agents: 500, concurrency: 0},
    "idle-1000" => %{workload: "idle", agents: 1_000, concurrency: 0},
    "active-10" => %{workload: "active", agents: 10, concurrency: 10},
    "active-25" => %{workload: "active", agents: 25, concurrency: 25},
    "active-50" => %{workload: "active", agents: 50, concurrency: 50},
    "wake-burst-100" => %{workload: "wake_storm", agents: 100, concurrency: 25},
    "wake-sustained-100" => %{workload: "wake_storm", agents: 100, concurrency: 25},
    "restart-recovery-25" => %{
      workload: "restart_recovery",
      agents: 25,
      concurrency: 25
    }
  }

  @type reason ::
          :missing
          | :unreadable
          | :too_large
          | :invalid_json
          | :invalid_schema_version
          | :not_claim_eligible
          | :invalid_suite_identity
          | :invalid_revision
          | :dirty_source
          | :invalid_host
          | :invalid_limits
          | :missing_workload_cell
          | :invalid_workload_cell
          | :insufficient_repetitions
          | :unmatched_repetitions
          | :invalid_trial
          | :missing_metrics
          | :failed_correctness
          | :invalid_raw_artifact
          | :checksum_mismatch

  @spec validate(Path.t(), %{cympho: String.t(), paperclip: String.t()}) ::
          {:ok, map()} | {:error, reason()}
  def validate(path, expected_revisions) when is_binary(path) and is_map(expected_revisions) do
    with :ok <- validate_expected_revisions(expected_revisions),
         {:ok, artifact} <- read_artifact(path),
         :ok <- validate_root(artifact),
         :ok <- validate_host(artifact["host"]),
         :ok <- validate_database(artifact["database"]),
         :ok <- validate_protocol(artifact["protocol"]),
         :ok <- validate_child_limits(artifact),
         :ok <- validate_products(artifact["products"], expected_revisions, artifact),
         {:ok, cell_count, repetition_count} <-
           validate_cells(artifact["workload_cells"], path, artifact) do
      {:ok, %{cell_count: cell_count, repetition_count: repetition_count}}
    end
  rescue
    _ -> {:error, :unreadable}
  catch
    _, _ -> {:error, :unreadable}
  end

  def validate(_path, _expected_revisions), do: {:error, :unreadable}

  @spec reason_label(reason()) :: String.t()
  def reason_label(:missing), do: "the comparative artifact is missing"
  def reason_label(:unreadable), do: "the comparative artifact could not be read safely"
  def reason_label(:too_large), do: "the comparative manifest exceeds its size limit"
  def reason_label(:invalid_json), do: "the comparative manifest is not valid JSON"
  def reason_label(:invalid_schema_version), do: "the comparative schema version is unsupported"
  def reason_label(:not_claim_eligible), do: "claim_eligible is not true"
  def reason_label(:invalid_suite_identity), do: "the suite identity or timestamp is invalid"
  def reason_label(:invalid_revision), do: "a product revision is missing, stale, or malformed"
  def reason_label(:dirty_source), do: "a measured product was built from a dirty source tree"
  def reason_label(:invalid_host), do: "Linux cgroup-v2 host evidence is incomplete"
  def reason_label(:invalid_limits), do: "the measured cgroup resource limits are incomplete"

  def reason_label(:missing_workload_cell),
    do: "a required idle, active, wake, or restart workload cell is missing"

  def reason_label(:invalid_workload_cell), do: "a required workload cell has the wrong shape"

  def reason_label(:insufficient_repetitions),
    do: "a product cell has fewer than five repetitions"

  def reason_label(:unmatched_repetitions), do: "product repetitions are not matched by trial id"
  def reason_label(:invalid_trial), do: "a benchmark repetition is malformed or duplicated"

  def reason_label(:missing_metrics),
    do: "a repetition is missing required resource or latency metrics"

  def reason_label(:failed_correctness),
    do: "a repetition failed correctness or resource-safety checks"

  def reason_label(:invalid_raw_artifact),
    do: "raw samples, events, or database evidence is invalid"

  def reason_label(:checksum_mismatch),
    do: "a referenced raw artifact failed checksum verification"

  def reason_label(_reason), do: "the comparative artifact is invalid"

  defp validate_expected_revisions(%{cympho: cympho, paperclip: paperclip}) do
    if revision?(cympho) and revision?(paperclip), do: :ok, else: {:error, :invalid_revision}
  end

  defp validate_expected_revisions(_), do: {:error, :invalid_revision}

  defp read_artifact(path) do
    with {:ok, before_snapshot} <- manifest_path_snapshot(path),
         {:ok, contents, descriptor_identity} <-
           stream_manifest(path, stat_file_identity(before_snapshot)),
         {:ok, after_snapshot} <- manifest_path_snapshot(path),
         true <- before_snapshot == after_snapshot,
         true <- stat_file_identity(after_snapshot) == descriptor_identity do
      case Jason.decode(contents) do
        {:ok, artifact} when is_map(artifact) -> {:ok, artifact}
        {:ok, _other} -> {:error, :invalid_json}
        {:error, %Jason.DecodeError{}} -> {:error, :invalid_json}
      end
    else
      {:error, :enoent} -> {:error, :missing}
      {:error, :too_large} -> {:error, :too_large}
      _ -> {:error, :unreadable}
    end
  end

  defp manifest_path_snapshot(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular} = stat} -> {:ok, stable_stat(stat)}
      {:ok, _not_regular} -> {:error, :unsafe_path}
      {:error, reason} -> {:error, reason}
    end
  end

  defp stream_manifest(path, expected_identity) do
    case File.open(path, [:read, :binary], fn io ->
           with {:ok, before_info} <- :file.read_file_info(io, [:raw]),
                true <- file_identity(before_info) == expected_identity,
                read_result <- read_limited(io, @max_manifest_bytes),
                {:ok, after_info} <- :file.read_file_info(io, [:raw]),
                true <- file_identity(before_info) == file_identity(after_info) do
             case read_result do
               {:ok, contents} -> {:ok, contents, file_identity(after_info)}
               {:error, _reason} = error -> error
             end
           else
             _ -> {:error, :unreadable}
           end
         end) do
      {:ok, result} -> result
      {:error, _reason} -> {:error, :unreadable}
    end
  end

  defp read_limited(io, limit), do: read_limited(io, limit, 0, [])

  defp read_limited(io, limit, size, chunks) do
    read_size = min(64 * 1024, limit - size + 1)

    case IO.binread(io, read_size) do
      :eof -> {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
      {:error, _reason} -> {:error, :unreadable}
      chunk when size + byte_size(chunk) > limit -> {:error, :too_large}
      chunk -> read_limited(io, limit, size + byte_size(chunk), [chunk | chunks])
    end
  end

  defp validate_root(artifact) do
    cond do
      not exact_keys?(artifact, @root_keys) ->
        {:error, :invalid_schema_version}

      artifact["schema"] != @schema_name or artifact["schema_version"] != @schema_version ->
        {:error, :invalid_schema_version}

      artifact["claim_eligible"] != true ->
        {:error, :not_claim_eligible}

      not non_empty_string?(artifact["suite_id"]) or not iso8601?(artifact["generated_at"]) ->
        {:error, :invalid_suite_identity}

      true ->
        :ok
    end
  end

  defp validate_products(products, expected, artifact) when is_map(products) do
    if exact_keys?(products, @products) do
      result =
        Enum.reduce_while(@products, :ok, fn product, :ok ->
          expected_revision = Map.fetch!(expected, String.to_existing_atom(product))

          case products[product] do
            %{
              "revision" => ^expected_revision,
              "dirty" => false,
              "runtime_config_sha256" => runtime_config_sha256,
              "database_config_sha256" => database_config_sha256,
              "runner_sha256" => runner_sha256,
              "app_cgroup_id" => app_cgroup_id,
              "database_cgroup_id" => database_cgroup_id,
              "app_limits" => app_limits,
              "database_limits" => database_limits
            } = source ->
              valid? =
                exact_keys?(source, @product_keys) and sha256?(runtime_config_sha256) and
                  database_config_sha256 == artifact["database"]["config_sha256"] and
                  runner_sha256 == artifact["protocol"]["runner_sha256"] and
                  non_empty_string?(app_cgroup_id) and non_empty_string?(database_cgroup_id) and
                  app_limits == artifact["protocol"]["app_limits"] and
                  database_limits == artifact["database"]["limits"]

              if valid?, do: {:cont, :ok}, else: {:halt, {:error, :invalid_revision}}

            %{"dirty" => dirty} when dirty != false ->
              {:halt, {:error, :dirty_source}}

            _ ->
              {:halt, {:error, :invalid_revision}}
          end
        end)

      cgroup_ids =
        Enum.flat_map(@products, fn product ->
          [products[product]["app_cgroup_id"], products[product]["database_cgroup_id"]]
        end)

      if result == :ok and Enum.uniq(cgroup_ids) == cgroup_ids,
        do: :ok,
        else: if(result == :ok, do: {:error, :invalid_limits}, else: result)
    else
      {:error, :invalid_revision}
    end
  end

  defp validate_products(_products, _expected, _artifact), do: {:error, :invalid_revision}

  defp validate_host(
         %{
           "os" => "linux",
           "kernel" => kernel,
           "architecture" => architecture,
           "cgroup" => %{"version" => 2, "controllers" => controllers} = cgroup,
           "limits" => limits
         } = host
       ) do
    with true <- exact_keys?(host, @host_keys),
         true <- exact_keys?(cgroup, @cgroup_keys),
         true <- non_empty_string?(kernel),
         true <- non_empty_string?(architecture),
         true <- is_list(controllers),
         true <- Enum.all?(~w(cpu memory pids), &(&1 in controllers)),
         :ok <- validate_limits(limits),
         true <- low_vps_limits?(limits) do
      :ok
    else
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_host}
    end
  end

  defp validate_host(_host), do: {:error, :invalid_host}

  defp validate_limits(
         %{
           "cpu_cores" => cpu_cores,
           "memory_max_bytes" => memory_max,
           "swap_max_bytes" => swap_max,
           "pids_max" => pids_max
         } = limits
       ) do
    if exact_keys?(limits, @limit_keys) and positive_number?(cpu_cores) and
         positive_integer?(memory_max) and
         non_negative_integer?(swap_max) and positive_integer?(pids_max) do
      :ok
    else
      {:error, :invalid_limits}
    end
  end

  defp validate_limits(_limits), do: {:error, :invalid_limits}

  defp validate_database(
         %{
           "engine" => "postgresql",
           "version" => version,
           "config_sha256" => config_sha256,
           "pool_size" => pool_size,
           "limits" => limits
         } = database
       ) do
    if exact_keys?(database, @database_keys) and non_empty_string?(version) and
         sha256?(config_sha256) and positive_integer?(pool_size) and
         validate_limits(limits) == :ok,
       do: :ok,
       else: {:error, :invalid_suite_identity}
  end

  defp validate_database(_database), do: {:error, :invalid_suite_identity}

  defp validate_protocol(
         %{
           "runner_sha256" => runner_sha256,
           "helper_sha256" => helper_sha256,
           "duration_ms" => duration_ms,
           "warmup_ms" => warmup_ms,
           "repetition_order" => "randomized_abba",
           "app_limits" => app_limits
         } = protocol
       ) do
    if exact_keys?(protocol, @protocol_keys) and sha256?(runner_sha256) and
         sha256?(helper_sha256) and positive_integer?(duration_ms) and
         positive_integer?(warmup_ms) and validate_limits(app_limits) == :ok,
       do: :ok,
       else: {:error, :invalid_suite_identity}
  end

  defp validate_protocol(_protocol), do: {:error, :invalid_suite_identity}

  defp validate_child_limits(artifact) do
    total = artifact["host"]["limits"]
    app = artifact["protocol"]["app_limits"]
    database = artifact["database"]["limits"]

    if app["cpu_cores"] + database["cpu_cores"] <= total["cpu_cores"] and
         app["memory_max_bytes"] + database["memory_max_bytes"] <=
           total["memory_max_bytes"] and
         app["swap_max_bytes"] + database["swap_max_bytes"] <= total["swap_max_bytes"] and
         app["pids_max"] + database["pids_max"] <= total["pids_max"],
       do: :ok,
       else: {:error, :invalid_limits}
  end

  defp low_vps_limits?(limits) do
    limits["cpu_cores"] <= 2 and limits["memory_max_bytes"] <= 2 * 1024 * 1024 * 1024 and
      limits["swap_max_bytes"] <= 2 * 1024 * 1024 * 1024 and limits["pids_max"] <= 4_096
  end

  defp validate_cells(cells, manifest_path, artifact) when is_list(cells) do
    cells_by_id = Map.new(cells, fn cell -> {cell["id"], cell} end)
    expected_ids = @required_cells |> Map.keys() |> Enum.sort()
    actual_ids = cells_by_id |> Map.keys() |> Enum.sort()

    if map_size(cells_by_id) != length(cells) or actual_ids != expected_ids do
      {:error, :invalid_workload_cell}
    else
      @required_cells
      |> Enum.reduce_while({:ok, 0, 0, %{}}, fn {id, expected},
                                                {:ok, cell_count, repetitions, raw_paths} ->
        case validate_cell(Map.fetch!(cells_by_id, id), expected, manifest_path, artifact) do
          {:ok, repetition_count, cell_raw_paths} ->
            if raw_artifacts_disjoint?(raw_paths, cell_raw_paths) do
              {:cont,
               {:ok, cell_count + 1, repetitions + repetition_count,
                Map.merge(raw_paths, cell_raw_paths)}}
            else
              {:halt, {:error, :invalid_trial}}
            end

          {:error, _reason} = error ->
            {:halt, error}
        end
      end)
      |> case do
        {:ok, cell_count, repetition_count, _raw_paths} ->
          {:ok, cell_count, repetition_count}

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp validate_cells(_cells, _manifest_path, _artifact), do: {:error, :missing_workload_cell}

  defp validate_cell(cell, expected, manifest_path, artifact) do
    with true <- exact_keys?(cell, @cell_keys),
         true <- cell["workload"] == expected.workload,
         true <- cell["agent_count"] == expected.agents,
         true <- cell["active_concurrency"] == expected.concurrency,
         true <- sha256?(cell["dataset_sha256"]),
         true <- sha256?(cell["scenario_sha256"]),
         true <- scenario_sha256(cell["scenario"]) == cell["scenario_sha256"],
         :ok <- validate_scenario(cell["id"], expected.workload, cell["scenario"]),
         %{} = results <- cell["products"],
         true <- exact_keys?(results, @products),
         {:ok, cympho_trials, cympho_raw_paths} <-
           validate_product_trials(
             results["cympho"],
             expected.workload,
             cell,
             manifest_path,
             artifact
           ),
         {:ok, paperclip_trials, paperclip_raw_paths} <-
           validate_product_trials(
             results["paperclip"],
             expected.workload,
             cell,
             manifest_path,
             artifact
           ),
         :ok <- validate_matched_trials(cympho_trials, paperclip_trials),
         :ok <- ensure_disjoint(cympho_raw_paths, paperclip_raw_paths) do
      {:ok, map_size(cympho_trials) + map_size(paperclip_trials),
       Map.merge(cympho_raw_paths, paperclip_raw_paths)}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_workload_cell}
    end
  end

  defp validate_product_trials(
         %{"repetitions" => repetitions} = result,
         workload,
         cell,
         manifest_path,
         artifact
       )
       when is_list(repetitions) do
    cond do
      not exact_keys?(result, @product_result_keys) ->
        {:error, :invalid_trial}

      length(repetitions) < 5 ->
        {:error, :insufficient_repetitions}

      true ->
        with {:ok, trials, raw_paths} <-
               collect_trials(repetitions, workload, cell, manifest_path, artifact),
             true <- map_size(trials) == length(repetitions) do
          {:ok, trials, raw_paths}
        else
          {:error, _reason} = error -> error
          _ -> {:error, :invalid_trial}
        end
    end
  end

  defp validate_product_trials(_result, _workload, _cell, _manifest_path, _artifact),
    do: {:error, :insufficient_repetitions}

  defp collect_trials(repetitions, workload, cell, manifest_path, artifact) do
    Enum.reduce_while(repetitions, {:ok, %{}, %{}}, fn repetition, {:ok, trials, raw_paths} ->
      case validate_trial(repetition, workload, cell, manifest_path, artifact) do
        {:ok, trial_id, trial_raw_paths} ->
          duplicate_raw_path? = not raw_artifacts_disjoint?(trial_raw_paths, raw_paths)

          if Map.has_key?(trials, trial_id) or duplicate_raw_path? do
            {:halt, {:error, :invalid_trial}}
          else
            {:cont, {:ok, Map.put(trials, trial_id, true), Map.merge(raw_paths, trial_raw_paths)}}
          end

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, trials, raw_paths} -> {:ok, trials, raw_paths}
      {:error, _reason} = error -> error
    end
  end

  defp validate_trial(
         %{
           "trial_id" => trial_id,
           "metrics" => metrics,
           "correctness" => correctness,
           "raw_artifacts" => raw_artifacts
         } = trial,
         workload,
         cell,
         manifest_path,
         artifact
       ) do
    with true <- exact_keys?(trial, @trial_keys),
         true <- non_empty_string?(trial_id),
         :ok <- validate_metrics(metrics, workload, artifact),
         :ok <- validate_correctness(correctness, workload, cell, metrics),
         {:ok, raw_paths} <- validate_raw_artifacts(raw_artifacts, manifest_path) do
      {:ok, trial_id, raw_paths}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_trial}
    end
  end

  defp validate_trial(_trial, _workload, _cell, _manifest_path, _artifact),
    do: {:error, :invalid_trial}

  defp validate_metrics(
         %{
           "app" => %{"rss_peak_bytes" => app_rss, "cpu_seconds" => app_cpu},
           "database" => %{
             "rss_peak_bytes" => database_rss,
             "cpu_seconds" => database_cpu,
             "query_count" => query_count,
             "queries_per_second" => query_rate
           },
           "children" => %{
             "rss_peak_bytes" => child_rss,
             "cpu_seconds" => child_cpu
           },
           "operation_count" => operation_count,
           "throughput_per_second" => throughput,
           "p95_latency_ms" => p95
         } = metrics,
         workload,
         artifact
       ) do
    duration_seconds = artifact["protocol"]["duration_ms"] / 1_000
    app_limits = artifact["protocol"]["app_limits"]
    database_limits = artifact["database"]["limits"]

    base_valid? =
      exact_keys?(metrics, @metric_keys) and
        exact_keys?(metrics["app"], @resource_metric_keys) and
        exact_keys?(metrics["database"], @database_metric_keys) and
        exact_keys?(metrics["children"], @resource_metric_keys) and
        positive_integer?(app_rss) and non_negative_number?(app_cpu) and
        positive_integer?(database_rss) and non_negative_number?(database_cpu) and
        non_negative_integer?(query_count) and non_negative_number?(query_rate) and
        non_negative_integer?(child_rss) and non_negative_number?(child_cpu) and
        non_negative_integer?(operation_count)

    workload_valid? =
      if workload in ["active", "wake_storm", "restart_recovery"] do
        positive_number?(throughput) and positive_number?(p95)
      else
        non_negative_number?(throughput) and non_negative_number?(p95)
      end

    limit_valid? =
      app_rss + child_rss <= app_limits["memory_max_bytes"] and
        database_rss <= database_limits["memory_max_bytes"] and
        app_cpu + child_cpu <= app_limits["cpu_cores"] * duration_seconds * @measurement_tolerance and
        database_cpu <=
          database_limits["cpu_cores"] * duration_seconds * @measurement_tolerance and
        rates_match?(query_count, query_rate, duration_seconds) and
        rates_match?(operation_count, throughput, duration_seconds)

    if base_valid? and workload_valid? and limit_valid?,
      do: :ok,
      else: {:error, :missing_metrics}
  end

  defp validate_metrics(_metrics, _workload, _artifact), do: {:error, :missing_metrics}

  defp validate_correctness(
         %{
           "pass" => true,
           "lost" => 0,
           "duplicate" => 0,
           "stranded" => 0,
           "oom_events" => 0,
           "recovery_failures" => 0,
           "restart_count" => restart_count,
           "applied_unique_wakes" => applied_unique_wakes,
           "recovered" => recovered,
           "completed" => completed
         } = correctness,
         workload,
         cell,
         metrics
       ) do
    expected_restart_count = if workload == "restart_recovery", do: 1, else: 0
    expected_wakes = if workload == "wake_storm", do: cell["scenario"]["unique_wakes"], else: 0

    expected_recovered =
      if workload == "restart_recovery", do: cell["scenario"]["running_at_restart"], else: 0

    expected_operations =
      case workload do
        "idle" -> 0
        "active" -> cell["scenario"]["total_operations"]
        "wake_storm" -> cell["scenario"]["unique_wakes"]
        "restart_recovery" -> cell["scenario"]["running_at_restart"]
      end

    if exact_keys?(correctness, @correctness_keys) and restart_count == expected_restart_count and
         applied_unique_wakes == expected_wakes and recovered == expected_recovered and
         metrics["operation_count"] == expected_operations and completed == expected_operations,
       do: :ok,
       else: {:error, :failed_correctness}
  end

  defp validate_correctness(_correctness, _workload, _cell, _metrics),
    do: {:error, :failed_correctness}

  defp validate_scenario(_id, "idle", scenario) do
    if exact_keys?(scenario, @idle_scenario_keys) and
         scenario == %{"kind" => "idle", "runnable_work" => 0},
       do: :ok,
       else: {:error, :invalid_workload_cell}
  end

  defp validate_scenario(_id, "active", scenario) do
    if exact_keys?(scenario, @active_scenario_keys) and scenario["kind"] == "active" and
         positive_integer?(scenario["total_operations"]),
       do: :ok,
       else: {:error, :invalid_workload_cell}
  end

  defp validate_scenario(id, "wake_storm", scenario) do
    expected_pattern = if id == "wake-burst-100", do: "burst", else: "sustained"

    if exact_keys?(scenario, @wake_scenario_keys) and scenario["kind"] == "wake_storm" and
         scenario["pattern"] == expected_pattern and positive_integer?(scenario["unique_wakes"]) and
         positive_integer?(scenario["repeated_deliveries"]),
       do: :ok,
       else: {:error, :invalid_workload_cell}
  end

  defp validate_scenario(_id, "restart_recovery", scenario) do
    if exact_keys?(scenario, @restart_scenario_keys) and
         scenario == %{
           "kind" => "restart_recovery",
           "restart_count" => 1,
           "running_at_restart" => 25
         },
       do: :ok,
       else: {:error, :invalid_workload_cell}
  end

  defp validate_scenario(_id, _workload, _scenario), do: {:error, :invalid_workload_cell}

  @doc false
  def scenario_sha256(scenario) when is_map(scenario) do
    scenario
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map_join(",", fn {key, value} -> Jason.encode!(key) <> ":" <> Jason.encode!(value) end)
    |> then(&("{" <> &1 <> "}"))
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  rescue
    _ -> nil
  end

  def scenario_sha256(_scenario), do: nil

  defp validate_raw_artifacts(raw_artifacts, manifest_path) when is_list(raw_artifacts) do
    kinds = Enum.map(raw_artifacts, & &1["kind"])

    if Enum.sort(kinds) == Enum.sort(@raw_artifact_kinds) do
      Enum.reduce_while(raw_artifacts, {:ok, %{}}, fn reference, {:ok, paths} ->
        case validate_raw_artifact(reference, manifest_path) do
          {:ok, path, identity} ->
            if Map.has_key?(paths, identity) do
              {:halt, {:error, :invalid_trial}}
            else
              {:cont, {:ok, Map.put(paths, identity, path)}}
            end

          {:error, _reason} = error ->
            {:halt, error}
        end
      end)
    else
      {:error, :invalid_raw_artifact}
    end
  end

  defp validate_raw_artifacts(_raw_artifacts, _manifest_path),
    do: {:error, :invalid_raw_artifact}

  defp validate_raw_artifact(
         %{"kind" => _kind, "path" => path, "sha256" => sha256} = reference,
         manifest_path
       ) do
    with true <- exact_keys?(reference, @raw_artifact_keys),
         true <- relative_path?(path),
         true <- sha256?(sha256),
         {:ok, root, candidate} <- confined_path(path, manifest_path),
         {:ok, actual_sha256, identity} <- file_sha256(root, candidate),
         true <- actual_sha256 == sha256 do
      {:ok, candidate, identity}
    else
      false when is_binary(path) and is_binary(sha256) -> {:error, :checksum_mismatch}
      {:ok, _not_regular} -> {:error, :invalid_raw_artifact}
      {:error, _reason} -> {:error, :invalid_raw_artifact}
      _ -> {:error, :invalid_raw_artifact}
    end
  end

  defp validate_raw_artifact(_reference, _manifest_path), do: {:error, :invalid_raw_artifact}

  defp confined_path(path, manifest_path) do
    root = manifest_path |> Path.expand() |> Path.dirname()
    candidate = Path.expand(path, root)

    if candidate != root and String.starts_with?(candidate, root <> "/") do
      {:ok, root, candidate}
    else
      {:error, :outside_manifest_directory}
    end
  end

  defp file_sha256(root, path) do
    with {:ok, before_snapshot} <- path_snapshot(root, path),
         {:ok, {digest, descriptor_identity}} <- stream_sha256(path),
         {:ok, after_snapshot} <- path_snapshot(root, path),
         true <- before_snapshot == after_snapshot,
         true <- snapshot_file_identity(after_snapshot) == descriptor_identity do
      {:ok, Base.encode16(digest, case: :lower), filesystem_identity(descriptor_identity)}
    else
      _ -> {:error, :unreadable}
    end
  rescue
    _ -> {:error, :unreadable}
  end

  defp stream_sha256(path) do
    File.open(path, [:read, :binary], fn io ->
      with {:ok, before_info} <- :file.read_file_info(io, [:raw]),
           digest <- hash_io(io, :crypto.hash_init(:sha256)),
           {:ok, after_info} <- :file.read_file_info(io, [:raw]),
           true <- file_identity(before_info) == file_identity(after_info) do
        {digest, file_identity(after_info)}
      else
        _ -> raise File.Error, reason: :estale, action: "read", path: "raw artifact"
      end
    end)
  end

  defp hash_io(io, digest) do
    case IO.binread(io, 64 * 1024) do
      :eof -> :crypto.hash_final(digest)
      {:error, reason} -> raise File.Error, reason: reason, action: "read", path: "raw artifact"
      chunk when is_binary(chunk) -> hash_io(io, :crypto.hash_update(digest, chunk))
    end
  end

  defp path_snapshot(root, path) do
    relative_parts = path |> Path.relative_to(root) |> Path.split()
    last_index = length(relative_parts) - 1

    with {:ok, %{type: :directory}} <- File.lstat(root) do
      relative_parts
      |> Enum.map_reduce(root, fn part, parent ->
        candidate = Path.join(parent, part)
        {candidate, candidate}
      end)
      |> elem(0)
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {candidate, index}, {:ok, snapshot} ->
        case File.lstat(candidate) do
          {:ok, %{type: :directory} = stat} when index < last_index ->
            {:cont, {:ok, [{candidate, stable_stat(stat)} | snapshot]}}

          {:ok, %{type: :regular, size: size} = stat}
          when index == last_index and size <= @max_raw_artifact_bytes ->
            {:cont, {:ok, [{candidate, stable_stat(stat)} | snapshot]}}

          _ ->
            {:halt, {:error, :unsafe_path}}
        end
      end)
    else
      _ -> {:error, :unsafe_path}
    end
  end

  defp stable_stat(stat) do
    Map.take(stat, [:type, :size, :inode, :major_device, :minor_device, :mode, :mtime, :ctime])
  end

  defp snapshot_file_identity([{_path, stat} | _snapshot]) do
    Map.take(stat, [:type, :size, :inode, :major_device, :minor_device, :mode])
  end

  defp snapshot_file_identity(_snapshot), do: nil

  defp file_identity(info) do
    %{
      type: file_info(info, :type),
      size: file_info(info, :size),
      inode: file_info(info, :inode),
      major_device: file_info(info, :major_device),
      minor_device: file_info(info, :minor_device),
      mode: file_info(info, :mode)
    }
  end

  defp stat_file_identity(stat) do
    Map.take(stat, [:type, :size, :inode, :major_device, :minor_device, :mode])
  end

  defp filesystem_identity(identity) do
    Map.take(identity, [:inode, :major_device, :minor_device])
  end

  defp validate_matched_trials(left, right) do
    if left |> Map.keys() |> Enum.sort() == right |> Map.keys() |> Enum.sort(),
      do: :ok,
      else: {:error, :unmatched_repetitions}
  end

  defp ensure_disjoint(left, right) do
    if raw_artifacts_disjoint?(left, right), do: :ok, else: {:error, :invalid_trial}
  end

  defp raw_artifacts_disjoint?(left, right) do
    left
    |> Map.keys()
    |> Enum.all?(&(not Map.has_key?(right, &1)))
  end

  defp rates_match?(count, rate, duration_seconds) do
    expected = count / duration_seconds
    tolerance = max(expected * 0.01, 0.001)
    abs(rate - expected) <= tolerance
  end

  defp revision?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{40,64}\z/, value)

  defp sha256?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp relative_path?(path) do
    is_binary(path) and path != "" and Path.type(path) in [:relative, :volumerelative] and
      not String.contains?(path, <<0>>)
  end

  defp iso8601?(value) when is_binary(value) do
    match?({:ok, _datetime, _offset}, DateTime.from_iso8601(value))
  end

  defp iso8601?(_value), do: false

  defp exact_keys?(map, expected) when is_map(map) do
    map |> Map.keys() |> Enum.sort() == Enum.sort(expected)
  end

  defp exact_keys?(_value, _expected), do: false

  defp non_empty_string?(value), do: is_binary(value) and String.trim(value) != ""
  defp positive_integer?(value), do: is_integer(value) and finite_number?(value) and value > 0

  defp non_negative_integer?(value),
    do: is_integer(value) and finite_number?(value) and value >= 0

  defp positive_number?(value), do: finite_number?(value) and value > 0
  defp non_negative_number?(value), do: finite_number?(value) and value >= 0

  defp finite_number?(value) when is_integer(value), do: abs(value) <= @max_numeric_metric

  defp finite_number?(value) when is_float(value) do
    value == value and abs(value) <= @max_numeric_metric
  end

  defp finite_number?(_value), do: false
end
