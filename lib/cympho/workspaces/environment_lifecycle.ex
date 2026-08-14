defmodule Cympho.Workspaces.EnvironmentLifecycle do
  @moduledoc """
  Acquire, reuse, and release remote environments through `EnvironmentDrivers`.

  Local workspaces (blank `provider_type`) are a no-op. When a provider is set,
  the registry resolves the driver (Fake only in this phase). Unknown providers
  fail closed. Provider refs are persisted on the execution workspace or lease.
  """

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

    case normalize_provider(ew.provider_type) do
      nil ->
        {:ok, ew}

      provider ->
        with {:ok, company_id} <- fetch_company_id(ew, opts),
             {:ok, driver} <- EnvironmentDrivers.resolve(provider) do
          if present?(ew.provider_ref) do
            {:ok, ew}
          else
            with {:ok, config} <- EnvironmentConfig.resolve(provider, company_id, ew.metadata) do
              acquire_and_persist(ew, driver, company_id, opts, config)
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

    case normalize_provider(ew.provider_type) do
      nil ->
        {:ok, ew}

      _provider when not is_binary(ew.provider_ref) or ew.provider_ref == "" ->
        {:ok, ew}

      provider ->
        with {:ok, driver} <- EnvironmentDrivers.resolve(provider),
             {:ok, config} <- EnvironmentConfig.resolve(provider, ew.company_id, ew.metadata),
             :ok <- driver.release(ew.provider_ref, release_opts(ew, opts, config)) do
          persist_provider_ref(ew, nil)
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

    case normalize_provider(ew.provider_type) do
      nil ->
        {:ok, ew}

      _provider when not is_binary(ew.provider_ref) or ew.provider_ref == "" ->
        {:ok, ew}

      provider ->
        with {:ok, driver} <- EnvironmentDrivers.resolve(provider),
             {:ok, config} <- EnvironmentConfig.resolve(provider, ew.company_id, ew.metadata) do
          driver_opts = release_opts(ew, opts, config)

          result =
            if function_exported?(driver, :cancel, 2) do
              driver.cancel(ew.provider_ref, driver_opts)
            else
              driver.release(ew.provider_ref, driver_opts)
            end

          case result do
            :ok -> persist_provider_ref(ew, nil)
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

      case normalize_provider(provider) do
        nil ->
          {:ok, attrs}

        normalized ->
          company_id = get_field(attrs, :company_id)

          metadata = get_field(attrs, :metadata) || %{}

          with {:ok, company_id} <- require_company_id(company_id),
               {:ok, driver} <- EnvironmentDrivers.resolve(normalized),
               {:ok, config} <- EnvironmentConfig.resolve(normalized, company_id, metadata) do
            case driver.acquire(%{company_id: company_id, metadata: metadata}, config) do
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
      metadata: Map.get(opts, :metadata) || Map.get(opts, "metadata") || %{}
    }

    case driver.acquire(acquire_opts, config) do
      {:ok, handle} ->
        persist_provider_ref(ew, handle.provider_ref)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp persist_provider_ref(%ExecutionWorkspace{} = ew, provider_ref) do
    ew
    |> ExecutionWorkspace.changeset(%{provider_ref: provider_ref})
    |> Repo.update()
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
