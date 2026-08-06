defmodule Cympho.Workspaces.Drivers.Fake do
  @moduledoc """
  In-memory `EnvironmentDriver` for contract tests and local development.

  Supports acquire → execute → reuse `provider_ref` → idempotent release.
  Secret-like keys in acquire metadata are redacted from the returned handle.
  """

  @behaviour Cympho.Workspaces.EnvironmentDriver

  @table :cympho_env_driver_fake
  @redacted "[REDACTED]"
  # Matched case-insensitively as whole segments (exact, prefix_, _suffix, or _mid_).
  @secret_segments ~w(secret token password api_key authorization credential auth key)

  @impl true
  def acquire(opts, config \\ %{})

  def acquire(opts, config) when is_list(opts), do: acquire(Map.new(opts), config)
  def acquire(opts, config) when is_list(config), do: acquire(opts, Map.new(config))

  def acquire(opts, config) when is_map(opts) and is_map(config) do
    case fetch_company_id(opts) do
      {:ok, company_id} ->
        ensure_table()
        provider_ref = "fake-" <> Ecto.UUID.generate()
        raw_metadata = merge_metadata(opts, config)
        metadata = redact_metadata(raw_metadata)

        entry = %{
          provider_ref: provider_ref,
          company_id: company_id,
          status: :acquired,
          metadata: metadata,
          executions: []
        }

        :ets.insert(@table, {provider_ref, entry})

        {:ok,
         %{
           provider_ref: provider_ref,
           company_id: company_id,
           provider: :fake,
           metadata: metadata
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def execute(handle, command, opts \\ %{})

  def execute(handle, command, opts) when is_list(opts),
    do: execute(handle, command, Map.new(opts))

  def execute(handle, command, opts) when is_map(opts) do
    ensure_table()
    provider_ref = provider_ref(handle)

    case :ets.lookup(@table, provider_ref) do
      [{^provider_ref, %{status: :acquired} = entry}] ->
        result = %{
          provider_ref: provider_ref,
          company_id: entry.company_id,
          command: command,
          status: :ok,
          stdout: "fake-ok",
          stderr: "",
          exit_code: 0,
          metadata: redact_metadata(Map.get(opts, :metadata) || Map.get(opts, "metadata") || %{})
        }

        updated = %{entry | executions: [result | entry.executions]}
        :ets.insert(@table, {provider_ref, updated})
        {:ok, result}

      [{^provider_ref, %{status: :released}}] ->
        {:error, :released}

      [] ->
        {:error, :not_acquired}
    end
  end

  @impl true
  def release(handle, opts \\ %{})

  def release(handle, opts) when is_list(opts), do: release(handle, Map.new(opts))

  def release(handle, _opts) do
    ensure_table()
    provider_ref = provider_ref(handle)

    case :ets.lookup(@table, provider_ref) do
      [{^provider_ref, entry}] ->
        :ets.insert(@table, {provider_ref, %{entry | status: :released}})
        :ok

      [] ->
        # Idempotent: unknown refs are treated as already gone.
        :ok
    end
  end

  @impl true
  def cancel(handle, opts \\ %{})

  def cancel(handle, opts) when is_list(opts), do: cancel(handle, Map.new(opts))

  def cancel(handle, opts) do
    # Fake has no in-flight work; cancel is release.
    release(handle, opts)
  end

  # --- Internals -------------------------------------------------------------

  defp fetch_company_id(opts) do
    company_id = Map.get(opts, :company_id) || Map.get(opts, "company_id")

    cond do
      is_binary(company_id) and String.trim(company_id) != "" ->
        {:ok, company_id}

      true ->
        {:error, :company_id_required}
    end
  end

  defp merge_metadata(opts, config) do
    base = Map.get(opts, :metadata) || Map.get(opts, "metadata") || %{}
    from_config = Map.get(config, :metadata) || Map.get(config, "metadata") || %{}

    base
    |> Map.merge(if is_map(from_config), do: from_config, else: %{})
  end

  defp provider_ref(%{provider_ref: ref}) when is_binary(ref), do: ref
  defp provider_ref(%{"provider_ref" => ref}) when is_binary(ref), do: ref
  defp provider_ref(ref) when is_binary(ref), do: ref

  defp redact_metadata(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      if secret_like_key?(key) do
        {key, @redacted}
      else
        {key, redact_value(value)}
      end
    end)
  end

  defp redact_metadata(_), do: %{}

  defp redact_value(value) when is_map(value), do: redact_metadata(value)
  defp redact_value(value) when is_list(value), do: Enum.map(value, &redact_value/1)
  defp redact_value(value), do: value

  defp secret_like_key?(key) do
    normalized =
      key
      |> to_string()
      |> String.downcase()
      |> String.replace("-", "_")

    Enum.any?(@secret_segments, fn part ->
      normalized == part or
        String.starts_with?(normalized, part <> "_") or
        String.ends_with?(normalized, "_" <> part) or
        String.contains?(normalized, "_" <> part <> "_")
    end)
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

      _tid ->
        :ok
    end
  rescue
    ArgumentError ->
      # Race: another process created the table between whereis and new.
      :ok
  end
end
