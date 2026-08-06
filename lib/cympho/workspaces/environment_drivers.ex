defmodule Cympho.Workspaces.EnvironmentDrivers do
  @moduledoc """
  Resolves environment-driver provider keys to implementing modules.

  Only the Fake driver is registered. Real providers (E2B, Daytona, etc.)
  remain intentionally unregistered — unknown keys fail closed.
  """

  alias Cympho.Workspaces.Drivers

  @type provider_key :: atom() | String.t()

  @registered %{
    fake: Drivers.Fake
  }

  @doc """
  Resolve a provider key to its driver module.

  Accepts atom or string keys (case-insensitive for strings). Unknown
  providers return `{:error, :unknown_provider}` (fail closed).
  """
  @spec resolve(provider_key()) :: {:ok, module()} | {:error, :unknown_provider}
  def resolve(provider) when is_atom(provider) do
    case Map.fetch(@registered, provider) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, :unknown_provider}
    end
  end

  def resolve(provider) when is_binary(provider) do
    provider
    |> String.trim()
    |> String.downcase()
    |> case do
      "" ->
        {:error, :unknown_provider}

      key ->
        try do
          resolve(String.to_existing_atom(key))
        rescue
          ArgumentError -> {:error, :unknown_provider}
        end
    end
  end

  def resolve(_provider), do: {:error, :unknown_provider}

  @doc """
  Known provider keys registered in this build.
  """
  @spec known_providers() :: [atom()]
  def known_providers, do: Map.keys(@registered)
end
