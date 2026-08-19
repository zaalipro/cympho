defmodule Cympho.Workspaces.EnvironmentLifecycle do
  @moduledoc """
  Acquire, reuse, and release remote environments through `EnvironmentDrivers`.

  Local workspaces (blank `provider_type`) are a no-op. When a provider is set,
  the registry resolves the driver (Fake only in this phase). Unknown providers
  fail closed. Provider refs are persisted on the execution workspace or lease.
  """

  import Ecto.Query, warn: false
  require Logger

  alias Cympho.Repo
  alias Cympho.Workspaces.Environment
  alias Cympho.Workspaces.EnvironmentConfig
  alias Cympho.Workspaces.EnvironmentDrivers
  alias Cympho.Workspaces.EnvironmentLease
  alias Cympho.Workspaces.ExecutionWorkspace

  @type opts :: map() | keyword()

  # ---------------------------------------------------------------------------
  # Execution workspace lifecycle
  # ---------------------------------------------------------------------------

  @doc """
  Ensure an execution workspace has an acquired provider environment.

  * blank `provider_type` → `{:ok, ew}` unchanged (local)
  * known provider + existing `provider_ref` → reuse (no re-acquire)
  * known provider + no ref → acquire and persist `provider_ref`
  * unknown provider → `{:error, :unknown_provider}`
  * missing `company_id` → `{:error, :company_id_required}`
  """
  @spec ensure_acquired(ExecutionWorkspace.t(), opts()) ::
          {:ok, ExecutionWorkspace.t()} | {:error, term()}
  def ensure_acquired(%ExecutionWorkspace{} = ew, opts \\ %{}) do
    opts = normalize_opts(opts)

    case Repo.get(ExecutionWorkspace, ew.id) do
      nil ->
        {:error, :execution_workspace_not_found}

      %ExecutionWorkspace{} = current ->
        ensure_current_acquired(current, opts)
    end
  end

  defp ensure_current_acquired(%ExecutionWorkspace{} = current, opts) do
    case normalize_provider(current.provider_type) do
      nil ->
        {:ok, current}

      provider ->
        with {:ok, company_id} <- fetch_company_id(current, opts),
             {:ok, driver} <- EnvironmentDrivers.resolve(provider) do
          if present?(current.provider_ref) do
            {:ok, current}
          else
            with {:ok, config} <-
                   EnvironmentConfig.resolve(provider, company_id, current.metadata) do
              acquire_and_persist(current, driver, company_id, opts, config)
            end
          end
        end
    end
  end

  @doc """
  Release the provider environment for an execution workspace.

  Idempotent: blank provider/ref is a no-op; driver release is idempotent.
  Clears `provider_ref` after a successful driver release so the next preflight
  re-acquires a fresh environment.
  """
  @spec release(ExecutionWorkspace.t(), opts()) ::
          {:ok, ExecutionWorkspace.t()} | {:error, term()}
  def release(%ExecutionWorkspace{} = ew, opts \\ %{}) do
    opts = normalize_opts(opts)
    current = Repo.get(ExecutionWorkspace, ew.id) || ew

    case normalize_provider(current.provider_type) do
      nil ->
        {:ok, current}

      _provider when not is_binary(current.provider_ref) or current.provider_ref == "" ->
        {:ok, current}

      provider ->
        with {:ok, driver} <- EnvironmentDrivers.resolve(provider),
             {:ok, config} <-
               EnvironmentConfig.resolve(provider, current.company_id, current.metadata),
             :ok <- driver.release(current.provider_ref, release_opts(current, opts, config)) do
          clear_provider_ref(current, current.provider_ref)
        end
    end
  end

  @doc """
  Cancel in-flight provider work and release. Falls back to `release/2` when the
  driver does not implement `cancel/2`. Idempotent.
  """
  @spec cancel(ExecutionWorkspace.t(), opts()) ::
          {:ok, ExecutionWorkspace.t()} | {:error, term()}
  def cancel(%ExecutionWorkspace{} = ew, opts \\ %{}) do
    opts = normalize_opts(opts)
    current = Repo.get(ExecutionWorkspace, ew.id) || ew

    case normalize_provider(current.provider_type) do
      nil ->
        {:ok, current}

      _provider when not is_binary(current.provider_ref) or current.provider_ref == "" ->
        {:ok, current}

      provider ->
        with {:ok, driver} <- EnvironmentDrivers.resolve(provider),
             {:ok, config} <-
               EnvironmentConfig.resolve(provider, current.company_id, current.metadata) do
          driver_opts = release_opts(current, opts, config)

          result =
            if function_exported?(driver, :cancel, 2) do
              driver.cancel(current.provider_ref, driver_opts)
            else
              driver.release(current.provider_ref, driver_opts)
            end

          case result do
            :ok -> clear_provider_ref(current, current.provider_ref)
            {:error, reason} -> {:error, reason}
          end
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Lease lifecycle
  # ---------------------------------------------------------------------------

  @doc """
  Attach a driver-acquired `provider_lease_id` when creating a lease.

  * no provider (attrs or linked environment) → attrs unchanged
  * known provider → acquire and put `provider_lease_id` / `acquired_at`
  * unknown provider → `{:error, :unknown_provider}`
  """
  @spec prepare_lease_attrs(map()) :: {:ok, map()} | {:error, term()}
  def prepare_lease_attrs(attrs) when is_map(attrs) do
    with {:ok, attrs} <- maybe_copy_provider_from_environment(attrs) do
      provider = get_field(attrs, :provider)

      case {normalize_provider(provider), get_field(attrs, :provider_lease_id)} do
        {_provider, provider_lease_id}
        when is_binary(provider_lease_id) and provider_lease_id != "" ->
          {:ok, attrs}

        {nil, _provider_lease_id} ->
          {:ok, attrs}

        {normalized, _provider_lease_id} ->
          company_id = get_field(attrs, :company_id)

          metadata = get_field(attrs, :metadata) || %{}

          idempotency_key =
            get_field(attrs, :idempotency_key) || get_field(metadata, :idempotency_key)

          with {:ok, company_id} <- require_company_id(company_id),
               {:ok, driver} <- EnvironmentDrivers.resolve(normalized),
               {:ok, config} <- EnvironmentConfig.resolve(normalized, company_id, metadata) do
            acquire_opts = %{
              company_id: company_id,
              idempotency_key: idempotency_key,
              metadata: metadata
            }

            case driver.acquire(acquire_opts, config) do
              {:ok, handle} ->
                now = DateTime.utc_now() |> DateTime.truncate(:second)

                attrs =
                  attrs
                  |> put_field(:provider, to_string(normalized))
                  |> put_field(:provider_lease_id, handle.provider_ref)
                  |> put_field(:acquired_at, get_field(attrs, :acquired_at) || now)

                {:ok, attrs}

              {:error, reason} ->
                {:error, reason}
            end
          end
      end
    end
  end

  @doc false
  @spec release_prepared_lease(map()) :: :ok | {:error, term()}
  def release_prepared_lease(attrs) when is_map(attrs) do
    provider = normalize_provider(get_field(attrs, :provider))
    provider_lease_id = get_field(attrs, :provider_lease_id)

    cond do
      is_nil(provider) or not present?(provider_lease_id) ->
        :ok

      true ->
        company_id = get_field(attrs, :company_id)
        metadata = get_field(attrs, :metadata) || %{}

        with {:ok, driver} <- EnvironmentDrivers.resolve(provider),
             {:ok, config} <- EnvironmentConfig.resolve(provider, company_id, metadata) do
          driver.release(provider_lease_id, Map.put(config, :company_id, company_id))
        end
    end
  end

  @doc """
  Release the provider environment backing a lease. Idempotent.
  """
  @spec release_for_lease(EnvironmentLease.t()) :: :ok | {:error, term()}
  def release_for_lease(%EnvironmentLease{} = lease) do
    case normalize_provider(lease.provider) do
      nil ->
        :ok

      _provider when not is_binary(lease.provider_lease_id) or lease.provider_lease_id == "" ->
        :ok

      provider ->
        case EnvironmentDrivers.resolve(provider) do
          {:ok, driver} ->
            case EnvironmentConfig.resolve(provider, lease.company_id, lease.metadata) do
              {:ok, config} ->
                driver.release(
                  lease.provider_lease_id,
                  Map.put(config, :company_id, lease.company_id)
                )

              {:error, reason} ->
                {:error, reason}
            end

          {:error, :unknown_provider} ->
            # Acquire is fail-closed; release of a removed provider is best-effort.
            Logger.warning(
              "environment lease release skipped unknown provider",
              component: "EnvironmentLifecycle",
              provider: lease.provider,
              lease_id: lease.id
            )

            :ok
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp acquire_and_persist(%ExecutionWorkspace{} = ew, driver, company_id, opts, config) do
    acquire_opts = %{
      company_id: company_id,
      idempotency_key: "execution_workspace:#{ew.id}",
      metadata: Map.get(opts, :metadata) || Map.get(opts, "metadata") || %{}
    }

    case driver.acquire(acquire_opts, config) do
      {:ok, handle} ->
        persist_acquired_provider_ref(ew, handle, driver, opts, config)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp persist_acquired_provider_ref(ew, handle, driver, opts, config) do
    persistence_result =
      try do
        Repo.transaction(fn ->
          now = DateTime.utc_now() |> DateTime.truncate(:second)

          {count, _rows} =
            ExecutionWorkspace
            |> where([current], current.id == ^ew.id)
            |> where([current], current.provider_type == ^ew.provider_type)
            |> where([current], is_nil(current.provider_ref) or current.provider_ref == "")
            |> Repo.update_all(set: [provider_ref: handle.provider_ref, updated_at: now])

          case {count, Repo.get(ExecutionWorkspace, ew.id)} do
            {1, %ExecutionWorkspace{} = updated} ->
              {:ok, updated}

            {0, %ExecutionWorkspace{provider_ref: ref} = winner}
            when is_binary(ref) and ref != "" ->
              {:reuse, winner}

            {0, nil} ->
              {:error, :execution_workspace_not_found}

            {0, _current} ->
              {:error, :provider_ref_compare_and_set_failed}
          end
        end)
        |> case do
          {:ok, result} -> result
          {:error, reason} -> {:error, reason}
        end
      rescue
        error -> {:error, error}
      catch
        kind, reason -> {:error, {kind, reason}}
      end

    case persistence_result do
      {:ok, updated} ->
        {:ok, updated}

      {:reuse, winner} ->
        if winner.provider_ref != handle.provider_ref do
          _ = compensate_acquisition(driver, handle, ew, opts, config)
        end

        {:ok, winner}

      {:error, reason} ->
        compensation = compensate_acquisition(driver, handle, ew, opts, config)

        if compensation != :ok do
          Logger.error("failed to compensate unpersisted provider environment",
            component: "EnvironmentLifecycle",
            execution_workspace_id: ew.id,
            provider_ref: handle.provider_ref,
            persistence_error: inspect(reason),
            compensation_error: inspect(compensation)
          )
        end

        {:error, {:provider_ref_persist_failed, reason}}
    end
  end

  defp compensate_acquisition(driver, handle, ew, opts, config) do
    driver.release(handle, release_opts(ew, opts, config))
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp clear_provider_ref(%ExecutionWorkspace{} = ew, expected_ref) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    ExecutionWorkspace
    |> where([current], current.id == ^ew.id and current.provider_ref == ^expected_ref)
    |> Repo.update_all(set: [provider_ref: nil, updated_at: now])

    case Repo.get(ExecutionWorkspace, ew.id) do
      %ExecutionWorkspace{} = current -> {:ok, current}
      nil -> {:error, :execution_workspace_not_found}
    end
  end

  defp maybe_copy_provider_from_environment(attrs) do
    provider = get_field(attrs, :provider)
    environment_id = get_field(attrs, :environment_id)

    cond do
      present?(provider) ->
        {:ok, attrs}

      not present?(environment_id) ->
        {:ok, attrs}

      true ->
        case Repo.get(Environment, environment_id) do
          %Environment{provider: env_provider} = env when is_binary(env_provider) ->
            if present?(env_provider) do
              attrs =
                attrs
                |> put_field(:provider, env_provider)
                |> maybe_put_company(env)

              {:ok, attrs}
            else
              {:ok, attrs}
            end

          _ ->
            {:ok, attrs}
        end
    end
  end

  defp maybe_put_company(attrs, %Environment{company_id: company_id}) do
    if present?(get_field(attrs, :company_id)) do
      attrs
    else
      put_field(attrs, :company_id, company_id)
    end
  end

  defp fetch_company_id(%ExecutionWorkspace{company_id: company_id}, opts) do
    opts_company = Map.get(opts, :company_id) || Map.get(opts, "company_id")
    require_company_id(company_id || opts_company)
  end

  defp require_company_id(company_id) when is_binary(company_id) do
    if String.trim(company_id) == "" do
      {:error, :company_id_required}
    else
      {:ok, company_id}
    end
  end

  defp require_company_id(_), do: {:error, :company_id_required}

  # Release and cancel have no separate config argument in the driver
  # behaviour, so resolved connection settings ride along in the opts map.
  # Caller-supplied opts still win.
  defp release_opts(%ExecutionWorkspace{} = ew, opts, config) do
    config
    |> Map.put(:company_id, ew.company_id)
    |> Map.merge(opts)
  end

  defp normalize_provider(nil), do: nil
  defp normalize_provider(""), do: nil

  defp normalize_provider(provider) when is_atom(provider),
    do: provider |> Atom.to_string() |> normalize_provider()

  defp normalize_provider(provider) when is_binary(provider) do
    trimmed = String.trim(provider)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_provider(_), do: nil

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false

  defp normalize_opts(opts) when is_list(opts), do: Map.new(opts)
  defp normalize_opts(opts) when is_map(opts), do: opts
  defp normalize_opts(_), do: %{}

  defp get_field(map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp put_field(map, key, value) when is_atom(key) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(map, key) -> Map.put(map, key, value)
      Map.has_key?(map, string_key) -> Map.put(map, string_key, value)
      true -> Map.put(map, key, value)
    end
  end
end
