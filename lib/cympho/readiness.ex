defmodule Cympho.Readiness do
  @moduledoc """
  Bounded, read-only application readiness checks.

  The public report deliberately exposes only a fixed schema and a small set
  of allowlisted states. Database errors, configuration, process identity, and
  migration counts are never returned by this module.
  """

  alias Cympho.BuildInfo
  alias Cympho.Repo

  @schema_version 1
  @default_timeout_ms 1_500
  @maximum_timeout_ms 5_000
  @query_timeout_ms 1_000

  @doc "Returns the stable, sanitized readiness schema used by the HTTP endpoint."
  @spec report(keyword() | map()) :: map()
  def report(opts \\ []) do
    if valid_options?(opts) do
      timeout_ms = timeout_ms(opts)
      callbacks = callbacks(option(opts, :callbacks), timeout_ms)

      callbacks
      |> bounded_checks(timeout_ms, option(opts, :task_supervisor) || Cympho.TaskSupervisor)
      |> public_report()
    else
      unavailable_report()
    end
  end

  @doc "Returns the HTTP status associated with a sanitized readiness report."
  @spec http_status(map()) :: 200 | 503
  def http_status(%{status: "ready"}), do: 200
  def http_status(_report), do: 503

  @doc false
  def timeout_ms(opts), do: bounded_timeout(option(opts, :timeout_ms))

  @doc false
  def valid_options?(opts) when is_map(opts), do: true
  def valid_options?(opts) when is_list(opts), do: Keyword.keyword?(opts)
  def valid_options?(_opts), do: false

  @doc false
  def unavailable_report, do: unavailable_checks() |> public_report()

  @doc false
  @spec public_report(map(), boolean()) :: map()
  def public_report(result, identity_valid? \\ BuildInfo.identity_valid?()) do
    raw_checks =
      case result do
        %{checks: checks} when is_map(checks) -> checks
        _other -> %{}
      end

    application_state =
      if identity_valid? == true,
        do: normalize_state(raw_checks, :application, [:ready]),
        else: :unavailable

    checks = %{
      application: application_state,
      database: normalize_state(raw_checks, :database, [:ready, :unavailable, :timeout]),
      migrations:
        normalize_state(raw_checks, :migrations, [:ready, :pending, :unavailable, :timeout])
    }

    %{
      schema_version: @schema_version,
      status:
        if(Enum.all?(checks, fn {_check, state} -> state == :ready end),
          do: "ready",
          else: "not_ready"
        ),
      service: "cympho",
      release: BuildInfo.release(),
      checks: Map.new(checks, fn {check, state} -> {check, Atom.to_string(state)} end)
    }
  end

  @doc false
  def default_database_probe(opts \\ []) do
    query_timeout_ms = Keyword.get(opts, :query_timeout_ms, @query_timeout_ms)
    query_opts = [timeout: query_timeout_ms, pool_timeout: query_timeout_ms]

    case Ecto.Adapters.SQL.query(Repo, "SELECT 1", [], query_opts) do
      {:ok, _result} -> :ok
      _failure -> {:error, :unavailable}
    end
  rescue
    _error -> {:error, :unavailable}
  catch
    _kind, _reason -> {:error, :unavailable}
  end

  @doc false
  def default_applied_migration_versions(opts \\ []) do
    query_timeout_ms = Keyword.get(opts, :query_timeout_ms, @query_timeout_ms)
    query_opts = [timeout: query_timeout_ms, pool_timeout: query_timeout_ms]

    with {:ok, %{rows: rows}} <-
           Ecto.Adapters.SQL.query(
             Repo,
             "SELECT version FROM schema_migrations",
             [],
             query_opts
           ),
         {:ok, versions} <- versions_from_rows(rows) do
      {:ok, versions}
    else
      _failure -> {:error, :unavailable}
    end
  rescue
    _error -> {:error, :unavailable}
  catch
    _kind, _reason -> {:error, :unavailable}
  end

  @doc false
  def packaged_migration_versions do
    migrations_path = Application.app_dir(:cympho, "priv/repo/migrations")
    paths = Path.wildcard(Path.join(migrations_path, "*.exs"))

    with false <- paths == [],
         {:ok, versions} <- parse_packaged_versions(paths),
         true <- MapSet.size(versions) == length(paths) do
      {:ok, versions}
    else
      _failure -> {:error, :unavailable}
    end
  rescue
    _error -> {:error, :unavailable}
  catch
    _kind, _reason -> {:error, :unavailable}
  end

  defp callbacks(overrides, timeout_ms) do
    defaults = %{
      database_probe: fn ->
        default_database_probe(query_timeout_ms: min(timeout_ms, @query_timeout_ms))
      end,
      applied_versions: fn ->
        default_applied_migration_versions(query_timeout_ms: min(timeout_ms, @query_timeout_ms))
      end,
      packaged_versions: &packaged_migration_versions/0
    }

    case overrides do
      value when is_map(value) -> Map.merge(defaults, value)
      value when is_list(value) -> Map.merge(defaults, Map.new(value))
      _other -> defaults
    end
  end

  defp bounded_checks(callbacks, timeout_ms, task_supervisor) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    case bounded_invoke(callbacks.database_probe, deadline, task_supervisor) do
      {:ok, :ok} ->
        bounded_migration_checks(callbacks, deadline, task_supervisor)

      {:ok, _failure} ->
        unavailable_checks()

      {:error, :unavailable} ->
        unavailable_checks()

      :timeout ->
        checks(:timeout, :unavailable)
    end
  rescue
    _error -> unavailable_checks()
  catch
    :exit, _reason -> unavailable_checks()
  end

  defp bounded_migration_checks(callbacks, deadline, task_supervisor) do
    with {:ok, applied_result} <-
           bounded_invoke(callbacks.applied_versions, deadline, task_supervisor),
         {:ok, applied_versions} <- normalize_versions(applied_result),
         {:ok, packaged_result} <-
           bounded_invoke(callbacks.packaged_versions, deadline, task_supervisor),
         {:ok, packaged_versions} <- normalize_versions(packaged_result) do
      migration_state =
        if MapSet.subset?(packaged_versions, applied_versions), do: :ready, else: :pending

      checks(:ready, migration_state)
    else
      :timeout -> checks(:ready, :timeout)
      _unavailable -> checks(:ready, :unavailable)
    end
  end

  defp bounded_invoke(callback, deadline, task_supervisor) when is_function(callback, 0) do
    remaining_ms = max(deadline - System.monotonic_time(:millisecond), 0)

    if remaining_ms == 0 do
      :timeout
    else
      task = Task.Supervisor.async_nolink(task_supervisor, fn -> invoke(callback) end)

      case Task.yield(task, remaining_ms) do
        {:ok, {:ok, result}} ->
          {:ok, result}

        {:ok, {:error, :unavailable}} ->
          {:error, :unavailable}

        {:exit, _reason} ->
          {:error, :unavailable}

        nil ->
          _ = Task.shutdown(task, :brutal_kill)
          :timeout
      end
    end
  rescue
    _error -> {:error, :unavailable}
  catch
    _kind, _reason -> {:error, :unavailable}
  end

  defp bounded_invoke(_callback, _deadline, _task_supervisor), do: {:error, :unavailable}

  defp invoke(callback) do
    {:ok, callback.()}
  rescue
    _error -> {:error, :unavailable}
  catch
    _kind, _reason -> {:error, :unavailable}
  end

  defp normalize_versions({:ok, %MapSet{} = versions}), do: validate_versions(versions)
  defp normalize_versions(%MapSet{} = versions), do: validate_versions(versions)

  defp normalize_versions({:ok, versions}) when is_list(versions) do
    versions |> MapSet.new() |> validate_versions()
  end

  defp normalize_versions(_value), do: :error

  defp validate_versions(%MapSet{} = versions) do
    if Enum.all?(versions, &(is_integer(&1) and &1 >= 0)), do: {:ok, versions}, else: :error
  end

  defp versions_from_rows(rows) when is_list(rows) do
    rows
    |> Enum.reduce_while({:ok, MapSet.new()}, fn
      [version], {:ok, versions} when is_integer(version) and version >= 0 ->
        {:cont, {:ok, MapSet.put(versions, version)}}

      _row, _versions ->
        {:halt, {:error, :unavailable}}
    end)
  end

  defp versions_from_rows(_rows), do: {:error, :unavailable}

  defp parse_packaged_versions(paths) do
    Enum.reduce_while(paths, {:ok, MapSet.new()}, fn path, {:ok, versions} ->
      case Integer.parse(Path.basename(path)) do
        {version, "_" <> _name} when version >= 0 ->
          if MapSet.member?(versions, version) do
            {:halt, {:error, :unavailable}}
          else
            {:cont, {:ok, MapSet.put(versions, version)}}
          end

        _invalid_name ->
          {:halt, {:error, :unavailable}}
      end
    end)
  end

  defp normalize_state(checks, key, allowed) do
    value = Map.get(checks, key)
    if value in allowed, do: value, else: :unavailable
  end

  defp option(opts, key) when is_list(opts) do
    if Keyword.keyword?(opts), do: Keyword.get(opts, key)
  end

  defp option(opts, key) when is_map(opts), do: Map.get(opts, key)
  defp option(_opts, _key), do: nil

  defp unavailable_checks do
    checks(:unavailable, :unavailable)
  end

  defp checks(database, migrations) do
    %{checks: %{application: :ready, database: database, migrations: migrations}}
  end

  defp bounded_timeout(timeout_ms)
       when is_integer(timeout_ms) and timeout_ms > 0 and timeout_ms <= @maximum_timeout_ms,
       do: timeout_ms

  defp bounded_timeout(_timeout_ms), do: @default_timeout_ms
end
