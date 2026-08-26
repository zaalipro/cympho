defmodule Cympho.Diagnostics do
  @moduledoc """
  Non-destructive operator diagnostics for a Cympho source checkout.

  The diagnostic runner deliberately does not start `Cympho.Application`.
  Database checks briefly start only the repository when it is not already
  running, and neither adapter providers nor the configured HTTP endpoint are
  called. Database and configuration checks are read-only. The local storage
  check creates one exclusive zero-byte probe and removes it immediately; it
  never touches an attachment record or payload. Reports contain an allowlisted
  set of operational facts and never serialize environment values, adapter
  configuration, or raw exceptions.
  """

  alias Cympho.Agents.Agent
  alias Cympho.Repo

  @schema_version 1
  @sensitive_key ~r/(password|secret|token|api.?key|authorization|cookie|credential|database.?url|dsn)/i
  @url_with_userinfo ~r"\b(?:ecto|postgres(?:ql)?|https?)://[^\s/@]+:[^\s/@]+@"i
  @sensitive_assignment ~r/(?:password|secret|token|api.?key|authorization|cookie|credential|dsn)\s*[:=]/i
  @allowed_detail_keys MapSet.new(~w(
    actual required pinned installed environment present missing invalid
    valid distinct public_scheme public_port listener_scope listener_port
    server_enabled probe_enabled backend absolute persistent writable configured
    memory_mb process_memory_mb binary_memory_mb ets_memory_mb process_count
    process_limit port_count port_limit schedulers_online run_queue profile
    repo_pool finch_pool max_concurrent_agents heartbeat_limit plugin_limit
    packaged_count applied_count pending_count highest_packaged highest_applied
    adapters type healthy degraded unavailable total unknown_count
  ))

  @type status :: :pass | :warn | :fail
  @type check :: %{
          id: String.t(),
          category: String.t(),
          status: status(),
          message: String.t(),
          details: map(),
          repair: String.t() | nil
        }

  @doc "Runs the fixed diagnostic check set without starting the application supervisor."
  @spec run(keyword()) :: map()
  def run(opts \\ []) do
    callbacks = callbacks(opts[:callbacks] || %{})
    env = callbacks.env
    environment = normalize_environment(callbacks.environment.())
    packaged_versions = callbacks.packaged_versions.()
    database = callbacks.database_snapshot.()

    checks =
      toolchain_checks(callbacks) ++
        config_checks(environment, env, callbacks) ++
        database_checks(database, packaged_versions) ++
        endpoint_checks(environment, callbacks, opts[:probe_endpoint] == true) ++
        storage_checks(environment, env, callbacks) ++
        import_spool_checks(environment, env, callbacks) ++
        runtime_checks(callbacks) ++ adapter_checks(database, callbacks)

    checks = Enum.map(checks, &sanitize_check/1)
    summary = summarize(checks)

    %{
      schema_version: @schema_version,
      generated_at: callbacks.now.() |> DateTime.to_iso8601(),
      application: %{
        name: "cympho",
        version: callbacks.application_version.(),
        environment: to_string(environment)
      },
      status: overall_status(summary),
      summary: summary,
      checks: checks
    }
  end

  @doc "Returns the command exit code for a report. Warnings fail only in strict mode."
  @spec exit_code(map(), boolean()) :: 0 | 1
  def exit_code(report, strict? \\ false) do
    summary = report.summary

    if summary.failed > 0 or (strict? and summary.warned > 0), do: 1, else: 0
  end

  @doc false
  def default_database_snapshot do
    _ = Application.load(:cympho)

    case Ecto.Migrator.with_repo(
           Repo,
           fn repo ->
             with {:ok, _} <- Ecto.Adapters.SQL.query(repo, "SELECT 1", [], timeout: 2_000) do
               %{
                 applied_versions: applied_migration_versions(repo),
                 adapter_counts: aggregate_adapters(repo)
               }
             end
           end,
           pool_size: 2,
           mode: :temporary
         ) do
      {:ok, {:error, reason}, _apps} -> {:error, classify_database_error(reason)}
      {:ok, snapshot, _apps} -> {:ok, snapshot}
      {:error, reason} -> {:error, classify_database_error(reason)}
    end
  rescue
    error -> {:error, classify_database_error(error)}
  catch
    :exit, reason -> {:error, classify_database_error(reason)}
  end

  @doc false
  def packaged_migration_versions do
    _ = Application.load(:cympho)

    Repo
    |> Ecto.Migrator.migrations_path()
    |> Path.join("*.exs")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      case Integer.parse(Path.basename(path)) do
        {version, _rest} -> [version]
        :error -> []
      end
    end)
    |> MapSet.new()
  rescue
    _ -> MapSet.new()
  end

  @doc false
  def local_storage_probe(path) do
    name = ".cympho-doctor-#{System.unique_integer([:positive, :monotonic])}"
    probe_path = Path.join(path, name)

    case File.open(probe_path, [:write, :exclusive]) do
      {:ok, io} ->
        try do
          :ok = File.close(io)
          :ok
        after
          _ = File.rm(probe_path)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  def tcp_probe(address, port) do
    address = connect_address(address)

    case :gen_tcp.connect(address, port, [:binary, active: false], 1_000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp callbacks(overrides) do
    defaults = %{
      env: &System.get_env/1,
      environment: fn -> Application.get_env(:cympho, :env, :unknown) end,
      app_env: fn key, default -> Application.get_env(:cympho, key, default) end,
      endpoint_config: fn -> Application.get_env(:cympho, CymphoWeb.Endpoint, []) end,
      find_executable: &System.find_executable/1,
      database_snapshot: &default_database_snapshot/0,
      packaged_versions: &packaged_migration_versions/0,
      local_storage_probe: &local_storage_probe/1,
      tcp_probe: &tcp_probe/2,
      runtime_snapshot: &default_runtime_snapshot/0,
      application_version: fn ->
        case Application.spec(:cympho, :vsn) do
          nil -> Mix.Project.config()[:version] || "unknown"
          version -> to_string(version)
        end
      end,
      now: &DateTime.utc_now/0
    }

    Map.merge(defaults, Map.new(overrides))
  end

  defp toolchain_checks(callbacks) do
    elixir_requirement = Mix.Project.config()[:elixir] || "unknown"
    elixir_actual = System.version()
    pins = tool_pins()
    elixir_pin = pins["elixir"]
    otp_pin = pins["erlang"]
    otp_actual = otp_version()
    git_path = callbacks.find_executable.("git")

    elixir_status =
      if Version.match?(elixir_actual, elixir_requirement), do: :pass, else: :fail

    otp_status =
      if otp_pin && major_version(otp_actual) != major_version(otp_pin), do: :fail, else: :pass

    [
      check(
        "toolchain.elixir",
        "toolchain",
        elixir_status,
        if(elixir_status == :pass,
          do: "Elixir satisfies the project requirement.",
          else: "Elixir does not satisfy the project requirement."
        ),
        %{actual: elixir_actual, required: elixir_requirement, pinned: elixir_pin},
        if(elixir_status == :fail, do: "Install the Elixir version pinned in .tool-versions.")
      ),
      check(
        "toolchain.otp",
        "toolchain",
        otp_status,
        if(otp_status == :pass,
          do: "Erlang/OTP has the required major version.",
          else: "Erlang/OTP has the wrong major version."
        ),
        %{actual: otp_actual, pinned: otp_pin},
        if(otp_status == :fail, do: "Install the Erlang/OTP version pinned in .tool-versions.")
      ),
      check(
        "toolchain.git",
        "toolchain",
        if(git_path, do: :pass, else: :fail),
        if(git_path,
          do: "Git is available for repository delivery.",
          else: "Git is not available."
        ),
        %{installed: not is_nil(git_path)},
        if(git_path,
          do: nil,
          else: "Install Git and ensure it is on PATH."
        )
      )
    ]
  end

  defp config_checks(environment, env, callbacks) do
    required = %{
      "APP_HOST" => &hostname?/1,
      "PREVIEW_HOST" => &hostname?/1,
      "DATABASE_URL" => &present?/1,
      "SECRET_KEY_BASE" => &minimum_bytes?(&1, 64),
      "LIVE_VIEW_SALT" => &minimum_bytes?(&1, 16),
      "CYMPHO_ENCRYPTION_KEY" => &(is_binary(&1) and byte_size(&1) == 32),
      "CYMPHO_USER_JWT_SECRET" => &minimum_bytes?(&1, 32),
      "CYMPHO_AGENT_JWT_SECRET" => &minimum_bytes?(&1, 32)
    }

    {missing, invalid} =
      if environment == :prod do
        Enum.reduce(required, {[], []}, fn {name, validator}, {missing, invalid} ->
          case env.(name) do
            value when value in [nil, ""] ->
              {[name | missing], invalid}

            value ->
              if validator.(value), do: {missing, invalid}, else: {missing, [name | invalid]}
          end
        end)
      else
        {[], []}
      end

    config_status = if missing == [] and invalid == [], do: :pass, else: :fail
    app_host = env.("APP_HOST") || endpoint_host(callbacks.endpoint_config.())

    preview_host =
      env.("PREVIEW_HOST") || callbacks.app_env.(:preview_host, nil) ||
        if(environment == :prod, do: nil, else: "preview.localhost")

    origins_valid? =
      hostname?(app_host) and hostname?(preview_host) and
        normalize_host(app_host) != normalize_host(preview_host)

    origin_status = if origins_valid?, do: :pass, else: :fail

    [
      check(
        "config.runtime",
        "config",
        config_status,
        if(config_status == :pass,
          do: "Required runtime secrets are present with valid shapes.",
          else: "Required production configuration is missing or malformed."
        ),
        %{
          environment: to_string(environment),
          present:
            if(environment == :prod,
              do: map_size(required) - length(missing) - length(invalid),
              else: 0
            ),
          missing: Enum.sort(missing),
          invalid: Enum.sort(invalid)
        },
        if(config_status == :fail,
          do:
            "Set the named variables in the service environment; rotate rather than reusing exposed values."
        )
      ),
      check(
        "config.origins",
        "config",
        origin_status,
        if(origin_status == :pass,
          do: "Application and preview origins are distinct valid hostnames.",
          else: "Application and preview origins must be distinct valid hostnames."
        ),
        %{
          configured: present?(app_host) and present?(preview_host),
          valid: hostname?(app_host) and hostname?(preview_host),
          distinct:
            hostname?(app_host) and hostname?(preview_host) and
              normalize_host(app_host) != normalize_host(preview_host)
        },
        if(origin_status == :fail,
          do: "Set APP_HOST and PREVIEW_HOST to different bare hostnames."
        )
      )
    ]
  end

  defp database_checks({:ok, snapshot}, packaged_versions) do
    case snapshot.applied_versions do
      {:ok, applied} -> migration_checks(applied, packaged_versions)
      applied when is_struct(applied, MapSet) -> migration_checks(applied, packaged_versions)
      {:error, _reason} -> migration_read_failure_checks()
    end
  end

  defp database_checks({:error, classification}, _packaged_versions) do
    [
      check(
        "database.connection",
        "database",
        :fail,
        database_error_message(classification),
        %{},
        "Check DATABASE_URL and PostgreSQL availability without pasting the URL into logs."
      ),
      check(
        "database.migrations",
        "database",
        :fail,
        "Migration state could not be checked because PostgreSQL is unavailable.",
        %{},
        "Repair the database connection, then rerun the doctor."
      )
    ]
  end

  defp migration_checks(applied, packaged_versions) do
    pending = MapSet.difference(packaged_versions, applied)
    missing_packaged = MapSet.difference(applied, packaged_versions)

    migration_status =
      if MapSet.size(pending) == 0 and MapSet.size(missing_packaged) == 0, do: :pass, else: :fail

    [
      check(
        "database.connection",
        "database",
        :pass,
        "PostgreSQL accepted a read-only query.",
        %{}
      ),
      check(
        "database.migrations",
        "database",
        migration_status,
        if(migration_status == :pass,
          do: "Database migrations match the packaged migration set.",
          else: "Database and packaged migrations do not match."
        ),
        %{
          packaged_count: MapSet.size(packaged_versions),
          applied_count: MapSet.size(applied),
          pending_count: MapSet.size(pending),
          highest_packaged: max_version(packaged_versions),
          highest_applied: max_version(applied)
        },
        if(migration_status == :fail, do: "Run mix ecto.migrate after taking a verified backup.")
      )
    ]
  end

  defp migration_read_failure_checks do
    [
      check(
        "database.connection",
        "database",
        :pass,
        "PostgreSQL accepted a read-only query.",
        %{}
      ),
      check(
        "database.migrations",
        "database",
        :fail,
        "PostgreSQL is reachable but its migration state could not be read.",
        %{},
        "Check schema permissions, then rerun the doctor."
      )
    ]
  end

  defp endpoint_checks(environment, callbacks, probe?) do
    config = callbacks.endpoint_config.()
    url = Keyword.get(config, :url, [])
    http = Keyword.get(config, :http, [])

    public_scheme =
      to_string(Keyword.get(url, :scheme, if(environment == :prod, do: "https", else: "http")))

    public_port = Keyword.get(url, :port)
    listener_address = Keyword.get(http, :ip, {127, 0, 0, 1})
    listener_port = Keyword.get(http, :port, public_port)
    server_enabled = Keyword.get(config, :server, false)

    configured? =
      is_integer(listener_port) and listener_port in 1..65_535 and
        (environment != :prod or (public_scheme == "https" and server_enabled == true))

    config_check =
      check(
        "endpoint.configuration",
        "endpoint",
        if(configured?, do: :pass, else: :fail),
        if(configured?,
          do: "Endpoint configuration is internally consistent.",
          else: "Endpoint configuration is incomplete."
        ),
        %{
          public_scheme:
            if(public_scheme in ["http", "https"], do: public_scheme, else: "invalid"),
          public_port: valid_port(public_port),
          listener_scope: listener_scope(listener_address),
          listener_port: valid_port(listener_port),
          server_enabled: server_enabled == true
        },
        if(configured?,
          do: nil,
          else: "Check APP_HOST, PORT, HTTP_BIND_IP, and production endpoint settings."
        )
      )

    probe_check =
      if probe? and configured? do
        case callbacks.tcp_probe.(listener_address, listener_port) do
          :ok ->
            check(
              "endpoint.transport",
              "endpoint",
              :pass,
              "The configured listener accepts TCP connections; this is not an application readiness check.",
              %{probe_enabled: true},
              nil
            )

          {:error, _reason} ->
            check(
              "endpoint.transport",
              "endpoint",
              :warn,
              "The configured listener did not accept a TCP connection; the service may be stopped.",
              %{probe_enabled: true},
              "Start the service and inspect its logs, then rerun with --probe-endpoint."
            )
        end
      else
        check(
          "endpoint.transport",
          "endpoint",
          :pass,
          "Live transport probe was not requested.",
          %{probe_enabled: false},
          nil
        )
      end

    [config_check, probe_check]
  end

  defp storage_checks(environment, env, callbacks) do
    backend = callbacks.app_env.(:storage_backend, Cympho.Attachments.Storage.LocalStorage)

    case backend do
      Cympho.Attachments.Storage.LocalStorage ->
        configured_path =
          env.("CYMPHO_UPLOADS_DIR") || callbacks.app_env.(:uploads_dir, "priv/static/uploads")

        path = Path.expand(configured_path)
        absolute? = Path.type(configured_path) == :absolute
        persistent? = environment != :prod or persistent_local_path?(path)

        probe =
          if File.dir?(path), do: callbacks.local_storage_probe.(path), else: {:error, :enoent}

        status = if persistent? and probe == :ok, do: :pass, else: :fail

        [
          check(
            "storage.configuration",
            "storage",
            status,
            cond do
              not persistent? ->
                "Production local storage must stay outside known temporary, checkout, and release payload paths."

              probe != :ok ->
                "Local attachment storage is missing or not writable."

              true ->
                "Local attachment storage is writable and outside known ephemeral or release paths."
            end,
            %{
              backend: "local",
              configured: present?(configured_path),
              absolute: absolute?,
              persistent: persistent?,
              writable: probe == :ok
            },
            if(status == :fail,
              do:
                "Set CYMPHO_UPLOADS_DIR to a persistent writable directory owned by the service user."
            )
          )
        ]

      Cympho.Attachments.Storage.S3Storage ->
        present = %{
          bucket: present?(callbacks.app_env.(:s3_bucket, nil)),
          access_key: present?(env.("AWS_ACCESS_KEY_ID")),
          secret_key: present?(env.("AWS_SECRET_ACCESS_KEY"))
        }

        configured? = Enum.all?(present, fn {_key, value} -> value end)

        [
          check(
            "storage.configuration",
            "storage",
            if(configured?, do: :pass, else: :fail),
            if(configured?,
              do:
                "S3 attachment storage has the required configuration; reachability was not probed.",
              else: "S3 attachment storage is missing required configuration."
            ),
            %{backend: "s3", configured: configured?},
            if(configured?, do: nil, else: "Set the documented S3 and AWS runtime variables.")
          )
        ]

      _other ->
        [
          check(
            "storage.configuration",
            "storage",
            :fail,
            "The configured attachment storage backend is unsupported.",
            %{backend: "unknown"},
            "Configure LocalStorage or S3Storage."
          )
        ]
    end
  end

  defp import_spool_checks(environment, env, callbacks) do
    configured_path =
      env.("CYMPHO_IMPORT_SPOOL_DIR") ||
        callbacks.app_env.(:company_import_transfer_spool_root, nil) ||
        if(environment == :prod, do: nil, else: Cympho.Companies.ImportTransferSpool.root())

    path = if is_binary(configured_path), do: Path.expand(configured_path)
    configured? = present?(env.("CYMPHO_IMPORT_SPOOL_DIR"))
    absolute? = is_binary(configured_path) and Path.type(configured_path) == :absolute
    persistent? = environment != :prod or persistent_local_path?(path)

    probe = probe_path_or_parent(path, callbacks.local_storage_probe)

    ready? =
      probe == :ok and
        (environment != :prod or (configured? and absolute? and persistent?))

    [
      check(
        "storage.import_spool",
        "storage",
        if(ready?, do: :pass, else: :fail),
        cond do
          environment == :prod and not configured? ->
            "Production import transfer storage is not explicitly configured."

          environment == :prod and not persistent? ->
            "Production import transfer storage must stay outside known temporary, checkout, and release payload paths."

          probe != :ok ->
            "Import transfer storage is missing or not writable."

          true ->
            "Import transfer storage is writable and has an acceptable path posture."
        end,
        %{
          configured: configured?,
          absolute: absolute?,
          persistent: persistent?,
          writable: probe == :ok
        },
        if(ready?,
          do: nil,
          else:
            "Set CYMPHO_IMPORT_SPOOL_DIR to an absolute persistent writable directory owned by the service user."
        )
      )
    ]
  end

  defp runtime_checks(callbacks) do
    snapshot = callbacks.runtime_snapshot.()
    repo_pool = callbacks.app_env.(Repo, []) |> Keyword.get(:pool_size, 10)
    finch_pool = finch_pool(callbacks.app_env.(Cympho.Finch, []))
    profile = callbacks.app_env.(:resource_profile, "balanced")

    reported_profile =
      if profile in ["low", "balanced", "throughput"], do: profile, else: "invalid"

    max_agents =
      callbacks.app_env.(:orchestrator, [])
      |> Keyword.get(:max_concurrent_agents)
      |> case do
        value when is_integer(value) and value > 0 -> value
        _ -> min(max(snapshot.schedulers_online * 2, 4), 32)
      end

    valid_resources? =
      profile in ["low", "balanced", "throughput"] and positive?(repo_pool) and
        positive?(finch_pool) and positive?(max_agents)

    [
      check(
        "runtime.beam",
        "runtime",
        :pass,
        "BEAM resource counters were collected from the doctor process.",
        snapshot,
        nil
      ),
      check(
        "runtime.resources",
        "runtime",
        if(valid_resources?, do: :pass, else: :fail),
        if(valid_resources?,
          do: "Resource profile and concurrency caps are valid.",
          else: "Resource limits are invalid."
        ),
        %{
          profile: reported_profile,
          repo_pool: valid_positive_integer(repo_pool),
          finch_pool: valid_positive_integer(finch_pool),
          max_concurrent_agents: max_agents,
          heartbeat_limit: 500,
          plugin_limit: 100
        },
        if(valid_resources?,
          do: nil,
          else: "Use a named resource profile with positive pool and agent limits."
        )
      )
    ]
  end

  defp adapter_checks({:ok, snapshot}, _callbacks) do
    supported = Agent |> Ecto.Enum.values(:adapter) |> Enum.map(&to_string/1) |> MapSet.new()

    adapter_counts =
      case snapshot.adapter_counts do
        {:ok, counts} -> counts
        counts when is_list(counts) -> counts
        {:error, _reason} -> []
      end

    adapters =
      adapter_counts
      |> Enum.group_by(& &1.type)
      |> Enum.map(fn {type, rows} ->
        counts = Map.new(rows, &{&1.status, &1.total})

        %{
          type: type,
          healthy: Map.get(counts, "healthy", 0),
          degraded: Map.get(counts, "degraded", 0),
          unavailable: Map.get(counts, "unavailable", 0),
          total: Enum.sum(Map.values(counts))
        }
      end)
      |> Enum.sort_by(& &1.type)

    unknown = adapters |> Enum.map(& &1.type) |> Enum.reject(&MapSet.member?(supported, &1))
    adapters = Enum.filter(adapters, &MapSet.member?(supported, &1.type))
    unhealthy = Enum.sum(Enum.map(adapters, &(&1.degraded + &1.unavailable)))

    inventory_failed? = match?({:error, _}, snapshot.adapter_counts)

    status =
      cond do
        inventory_failed? -> :fail
        unknown != [] -> :fail
        unhealthy > 0 -> :warn
        true -> :pass
      end

    check(
      "adapters.inventory",
      "adapters",
      status,
      cond do
        inventory_failed? -> "Adapter inventory could not be read."
        unknown != [] -> "Agents reference unsupported adapter types."
        unhealthy > 0 -> "Some agents have degraded or unavailable persisted adapter health."
        true -> "Configured agent adapter types and persisted health are valid."
      end,
      %{adapters: adapters, unknown_count: length(unknown)},
      if(status == :pass,
        do: nil,
        else: "Open Operations and repair the affected adapter type before dispatching work."
      )
    )
    |> List.wrap()
  end

  defp adapter_checks({:error, _reason}, _callbacks) do
    [
      check(
        "adapters.inventory",
        "adapters",
        :fail,
        "Adapter inventory could not be checked because PostgreSQL is unavailable.",
        %{adapters: [], unknown_count: 0},
        "Repair the database connection, then rerun the doctor."
      )
    ]
  end

  defp applied_migration_versions(repo) do
    with {:ok, %{rows: [[table]]}} <-
           Ecto.Adapters.SQL.query(
             repo,
             "SELECT to_regclass('public.schema_migrations')::text",
             [],
             timeout: 2_000
           ) do
      if is_nil(table) do
        {:ok, MapSet.new()}
      else
        case Ecto.Adapters.SQL.query(repo, "SELECT version FROM schema_migrations", [],
               timeout: 2_000
             ) do
          {:ok, %{rows: rows}} -> {:ok, rows |> Enum.map(&List.first/1) |> MapSet.new()}
          {:error, reason} -> {:error, reason}
        end
      end
    end
  end

  defp aggregate_adapters(repo) do
    sql = """
    SELECT adapter, health_status, count(*)::bigint
    FROM agents
    GROUP BY adapter, health_status
    ORDER BY adapter, health_status
    """

    case Ecto.Adapters.SQL.query(repo, sql, [], timeout: 2_000) do
      {:ok, %{rows: rows}} ->
        {:ok,
         Enum.map(rows, fn [type, status, total] ->
           %{type: to_string(type), status: to_string(status), total: total}
         end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp default_runtime_snapshot do
    memory = Map.new(:erlang.memory())

    %{
      memory_mb: bytes_to_mb(memory[:total]),
      process_memory_mb: bytes_to_mb(memory[:processes_used] || memory[:processes]),
      binary_memory_mb: bytes_to_mb(memory[:binary]),
      ets_memory_mb: bytes_to_mb(memory[:ets]),
      process_count: :erlang.system_info(:process_count),
      process_limit: :erlang.system_info(:process_limit),
      port_count: :erlang.system_info(:port_count),
      port_limit: :erlang.system_info(:port_limit),
      schedulers_online: :erlang.system_info(:schedulers_online),
      run_queue: :erlang.statistics(:run_queue)
    }
  end

  defp check(id, category, status, message, details, repair \\ nil) do
    %{
      id: id,
      category: category,
      status: status,
      message: message,
      details: details,
      repair: repair
    }
  end

  defp sanitize_check(check) do
    %{
      id: check.id,
      category: check.category,
      status: check.status,
      message: sanitize_string(check.message),
      details: sanitize_details(check.details),
      repair: if(check.repair, do: sanitize_string(check.repair))
    }
  end

  defp sanitize_details(details) when is_map(details) do
    Enum.reduce(details, %{}, fn {key, value}, acc ->
      normalized = to_string(key)

      if MapSet.member?(@allowed_detail_keys, normalized) and
           not Regex.match?(@sensitive_key, to_string(key)) do
        Map.put(acc, key, sanitize_value(value))
      else
        acc
      end
    end)
  end

  defp sanitize_value(value) when is_binary(value), do: sanitize_string(value)

  defp sanitize_value(value)
       when is_atom(value) or is_number(value) or is_boolean(value) or is_nil(value), do: value

  defp sanitize_value(value) when is_list(value), do: Enum.map(value, &sanitize_value/1)
  defp sanitize_value(value) when is_map(value), do: sanitize_details(value)
  defp sanitize_value(_value), do: "[redacted]"

  defp sanitize_string(value) do
    if Regex.match?(@url_with_userinfo, value) or Regex.match?(@sensitive_assignment, value),
      do: "[redacted]",
      else: value
  end

  defp summarize(checks) do
    %{
      passed: Enum.count(checks, &(&1.status == :pass)),
      warned: Enum.count(checks, &(&1.status == :warn)),
      failed: Enum.count(checks, &(&1.status == :fail))
    }
  end

  defp overall_status(%{failed: failed}) when failed > 0, do: :fail
  defp overall_status(%{warned: warned}) when warned > 0, do: :warn
  defp overall_status(_summary), do: :pass

  defp classify_database_error(reason) do
    text = inspect(reason, limit: 20, printable_limit: 200)

    cond do
      text =~ "schema_migrations" -> :schema_unavailable
      text =~ "timeout" -> :timeout
      text =~ "connection" or text =~ "econnrefused" -> :unreachable
      true -> :unavailable
    end
  end

  defp database_error_message(:timeout),
    do: "PostgreSQL did not answer within the diagnostic timeout."

  defp database_error_message(:schema_unavailable),
    do: "PostgreSQL is reachable but its migration schema could not be read."

  defp database_error_message(_),
    do: "PostgreSQL is not reachable with the configured runtime connection."

  defp tool_pins do
    case File.read(".tool-versions") do
      {:ok, body} ->
        body
        |> String.split("\n", trim: true)
        |> Enum.reduce(%{}, fn line, acc ->
          case String.split(line, ~r/\s+/, parts: 2) do
            [tool, version] -> Map.put(acc, tool, version)
            _ -> acc
          end
        end)

      _ ->
        %{}
    end
  end

  defp otp_version do
    major = to_string(:erlang.system_info(:otp_release))
    path = Path.join([to_string(:code.root_dir()), "releases", major, "OTP_VERSION"])

    case File.read(path) do
      {:ok, version} -> String.trim(version)
      _ -> major
    end
  end

  defp major_version(value) when is_binary(value), do: value |> String.split(".") |> List.first()
  defp major_version(_value), do: nil

  defp endpoint_host(config), do: config |> Keyword.get(:url, []) |> Keyword.get(:host)

  defp normalize_environment(environment) when environment in [:dev, :test, :prod],
    do: environment

  defp normalize_environment(_environment), do: :unknown

  defp hostname?(value) when is_binary(value) do
    Regex.match?(
      ~r/\A(?=.{1,253}\z)(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)*[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\z/,
      value
    )
  end

  defp hostname?(_value), do: false

  defp normalize_host(value) when is_binary(value),
    do: value |> String.downcase() |> String.trim_trailing(".")

  defp normalize_host(_value), do: nil

  defp minimum_bytes?(value, count), do: is_binary(value) and byte_size(value) >= count
  defp present?(value), do: is_binary(value) and String.trim(value) != ""
  defp positive?(value), do: is_integer(value) and value > 0
  defp valid_positive_integer(value) when is_integer(value) and value > 0, do: value
  defp valid_positive_integer(_value), do: "invalid"
  defp valid_port(value) when is_integer(value) and value in 1..65_535, do: value
  defp valid_port(_value), do: nil

  # A process cannot prove that a filesystem mount survives replacement or has
  # backups. Fail known-dangerous shapes and describe the narrower fact instead
  # of equating every absolute path with durability.
  defp persistent_local_path?(path) when is_binary(path) do
    expanded = Path.expand(path)
    components = Path.split(expanded)

    absolute_path?(expanded) and
      not path_within?(expanded, File.cwd!()) and
      not Enum.any?(known_ephemeral_roots(), &path_within?(expanded, &1)) and
      not Enum.any?(["_build", "releases", "current"], &(&1 in components)) and
      not String.contains?(expanded, "/priv/static/")
  end

  defp persistent_local_path?(_path), do: false

  defp probe_path_or_parent(path, probe) when is_binary(path) do
    cond do
      File.dir?(path) -> probe.(path)
      File.exists?(path) -> {:error, :not_a_directory}
      File.dir?(Path.dirname(path)) -> probe.(Path.dirname(path))
      true -> {:error, :enoent}
    end
  end

  defp probe_path_or_parent(_path, _probe), do: {:error, :enoent}

  defp known_ephemeral_roots do
    [System.tmp_dir!(), "/tmp", "/var/tmp", "/run", "/dev/shm"]
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
  end

  defp path_within?(path, root) do
    relative = Path.relative_to(Path.expand(path), Path.expand(root))

    relative == "." or
      (Path.type(relative) == :relative and relative != ".." and
         not String.starts_with?(relative, "../"))
  end

  defp absolute_path?(path), do: Path.type(path) == :absolute

  defp max_version(versions) do
    if MapSet.size(versions) == 0, do: nil, else: Enum.max(versions)
  end

  defp finch_pool(config) do
    config
    |> Keyword.get(:pools, [])
    |> Keyword.get(:default, [])
    |> Keyword.get(:size, 5)
  end

  defp bytes_to_mb(nil), do: 0.0
  defp bytes_to_mb(bytes), do: Float.round(bytes / 1_048_576, 1)

  defp listener_scope({127, _, _, _}), do: "loopback"
  defp listener_scope({0, 0, 0, 0, 0, 0, 0, 1}), do: "loopback"
  defp listener_scope({0, 0, 0, 0}), do: "wildcard"
  defp listener_scope({0, 0, 0, 0, 0, 0, 0, 0}), do: "wildcard"
  defp listener_scope(_address), do: "specific"

  defp connect_address({0, 0, 0, 0}), do: {127, 0, 0, 1}
  defp connect_address({0, 0, 0, 0, 0, 0, 0, 0}), do: {0, 0, 0, 0, 0, 0, 0, 1}
  defp connect_address(address), do: address
end
