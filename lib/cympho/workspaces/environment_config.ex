defmodule Cympho.Workspaces.EnvironmentConfig do
  @moduledoc """
  Builds `EnvironmentDriver` config for a provider, company, and workspace.

  Drivers stay pure: they receive a settings map and never reach for global
  state. This module is the one place that decides where those settings come
  from, in increasing order of precedence:

    1. deployment config — `config :cympho, :environment_providers, ssh: [...]`
    2. allowlisted non-secret fields on the workspace/lease `metadata`
    3. credentials read from the company's encrypted secret store

  Credentials are deliberately *not* readable from metadata. A workspace row can
  name a secret (`"password_secret_key" => "ssh_password"`) but can never carry
  the value, so a compromised or hand-edited metadata map cannot introduce a
  credential and cannot exfiltrate one by being rendered.

  Unknown providers and missing secrets fail closed.
  """

  alias Cympho.Secrets

  # Non-secret connection fields a workspace may override.
  @metadata_allowlist ~w(
    host
    port
    user
    workspace_root
    host_key_fingerprint
    accept_unknown_host_key
    connect_timeout
    command_timeout
    max_output_bytes
  )

  # Metadata may only *name* a secret; the value always comes from the store.
  @credential_refs %{
    "password_secret_key" => :password,
    "private_key_secret_key" => :private_key,
    "passphrase_secret_key" => :passphrase
  }

  @doc """
  Resolve driver config.

  * `:fake` and blank providers need no configuration and return `{:ok, %{}}`.
  * `:ssh` merges deployment config, allowlisted metadata, and secret-store
    credentials.
  * anything else fails closed with `{:error, :unknown_provider}`.
  """
  @spec resolve(atom() | String.t() | nil, String.t() | nil, map() | nil) ::
          {:ok, map()} | {:error, term()}
  def resolve(provider, company_id, metadata \\ %{})

  def resolve(nil, _company_id, _metadata), do: {:ok, %{}}
  def resolve("", _company_id, _metadata), do: {:ok, %{}}

  def resolve(provider, company_id, metadata) when is_atom(provider) do
    resolve(Atom.to_string(provider), company_id, metadata)
  end

  def resolve(provider, company_id, metadata) when is_binary(provider) do
    case provider |> String.trim() |> String.downcase() do
      "" -> {:ok, %{}}
      "fake" -> {:ok, %{}}
      "ssh" -> resolve_ssh(company_id, normalize_metadata(metadata))
      _ -> {:error, :unknown_provider}
    end
  end

  def resolve(_provider, _company_id, _metadata), do: {:error, :unknown_provider}

  # --- SSH --------------------------------------------------------------------

  defp resolve_ssh(company_id, metadata) do
    base = deployment_config(:ssh)
    overrides = Map.take(metadata, @metadata_allowlist)
    settings = Map.merge(base, overrides)

    with {:ok, auth} <- resolve_auth(company_id, base, metadata) do
      {:ok, Map.put(settings, "auth", auth)}
    end
  end

  # Private keys take precedence over passwords when both are configured, so
  # rotating a company onto key auth does not silently keep using the password.
  defp resolve_auth(company_id, base, metadata) do
    refs = credential_refs(base, metadata)

    cond do
      Map.has_key?(refs, :private_key) ->
        with {:ok, private_key} <- fetch_secret(company_id, refs[:private_key]),
             {:ok, passphrase} <- fetch_optional_secret(company_id, refs[:passphrase]) do
          {:ok, %{type: :private_key, private_key: private_key, passphrase: passphrase}}
        end

      Map.has_key?(refs, :password) ->
        with {:ok, password} <- fetch_secret(company_id, refs[:password]) do
          {:ok, %{type: :password, password: password}}
        end

      true ->
        {:error, :no_credential_configured}
    end
  end

  defp credential_refs(base, metadata) do
    Enum.reduce(@credential_refs, %{}, fn {metadata_key, kind}, acc ->
      case string_value(metadata, metadata_key) || string_value(base, metadata_key) do
        nil -> acc
        key -> Map.put(acc, kind, key)
      end
    end)
  end

  defp fetch_secret(company_id, key) when is_binary(company_id) and is_binary(key) do
    with {:ok, secret} <- get_secret_by_key(company_id, key),
         {:ok, value} <- Secrets.get_secret_value(secret.id) do
      {:ok, value}
    else
      _ -> {:error, {:secret_not_found, key}}
    end
  end

  defp fetch_secret(_company_id, _key), do: {:error, :company_id_required}

  defp fetch_optional_secret(_company_id, nil), do: {:ok, nil}

  defp fetch_optional_secret(company_id, key) do
    case fetch_secret(company_id, key) do
      {:ok, value} -> {:ok, value}
      {:error, _reason} -> {:ok, nil}
    end
  end

  defp get_secret_by_key(company_id, key) do
    Secrets.get_secret_by_key(company_id, key)
  rescue
    _ -> {:error, :secret_lookup_failed}
  end

  # --- Helpers ----------------------------------------------------------------

  defp deployment_config(provider) do
    :cympho
    |> Application.get_env(:environment_providers, [])
    |> get_provider(provider)
    |> normalize_metadata()
  end

  defp get_provider(config, provider) when is_list(config), do: Keyword.get(config, provider, [])
  defp get_provider(config, provider) when is_map(config), do: Map.get(config, provider, %{})
  defp get_provider(_config, _provider), do: %{}

  defp normalize_metadata(metadata) when is_map(metadata) do
    Map.new(metadata, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_metadata(metadata) when is_list(metadata) do
    metadata |> Map.new() |> normalize_metadata()
  end

  defp normalize_metadata(_metadata), do: %{}

  defp string_value(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) ->
        if String.trim(value) == "", do: nil, else: value

      _ ->
        nil
    end
  end
end
