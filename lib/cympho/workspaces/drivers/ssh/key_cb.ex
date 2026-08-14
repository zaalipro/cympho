defmodule Cympho.Workspaces.Drivers.Ssh.KeyCb do
  @moduledoc """
  In-memory `:ssh_client_key_api` callback for `Cympho.Workspaces.Drivers.Ssh`.

  OTP's default callback (`:ssh_file`) reads keys and `known_hosts` from disk.
  Cympho keeps SSH credentials in the encrypted company secret store, so this
  module answers both questions from the connect options instead:

  * `is_host_key/5` accepts a host key only when its SHA-256 fingerprint matches
    the pinned `:host_key_fingerprint`, or when the operator explicitly opted
    into `accept_unknown_host_key: true`.
  * `user_key/2` decodes a PEM or OpenSSH private key held in memory and only
    offers it for algorithms that key can actually sign.

  Nothing is written to disk and no host key is ever learned implicitly, so
  `add_host_key/4` is a no-op refusal.
  """

  @behaviour :ssh_client_key_api

  @impl true
  def is_host_key(key, _host, _port, _algorithm, opts) do
    private = private(opts)

    case Keyword.get(private, :host_key_fingerprint) do
      pinned when is_binary(pinned) and pinned != "" ->
        fingerprint_matches?(key, pinned)

      _ ->
        Keyword.get(private, :accept_unknown_host_key) == true
    end
  end

  @impl true
  def user_key(algorithm, opts) do
    private = private(opts)

    case Keyword.get(private, :auth) do
      %{type: :private_key, private_key: pem} = auth ->
        with {:ok, key} <- decode_private_key(pem, Map.get(auth, :passphrase)) do
          if algorithm_supported?(algorithm, key) do
            {:ok, key}
          else
            {:error, :algorithm_mismatch}
          end
        end

      _ ->
        {:error, :no_private_key_configured}
    end
  end

  @impl true
  def add_host_key(_hosts, _port, _key, _opts), do: {:error, :host_key_learning_disabled}

  # --- Internals --------------------------------------------------------------

  defp private(opts) when is_list(opts) do
    case Keyword.get(opts, :key_cb_private) do
      private when is_list(private) -> private
      _ -> []
    end
  end

  defp private(opts) when is_map(opts) do
    case Map.get(opts, :key_cb_private) do
      private when is_list(private) -> private
      _ -> []
    end
  end

  defp private(_opts), do: []

  defp fingerprint_matches?(key, pinned) do
    actual = :sha256 |> :ssh.hostkey_fingerprint(key) |> to_string()
    normalize_fingerprint(actual) == normalize_fingerprint(pinned)
  rescue
    _ -> false
  end

  # Accepts "SHA256:abc", "sha256:abc", or a bare "abc"; the digest itself stays
  # case-sensitive because it is base64.
  defp normalize_fingerprint(value) do
    value
    |> String.trim()
    |> String.replace_prefix("SHA256:", "")
    |> String.replace_prefix("sha256:", "")
    |> String.trim_trailing("=")
  end

  defp decode_private_key(pem, passphrase) when is_binary(pem) do
    case decode_openssh(pem) do
      {:ok, key} -> {:ok, key}
      :error -> decode_pem(pem, passphrase)
    end
  end

  defp decode_private_key(_pem, _passphrase), do: {:error, :invalid_private_key}

  # OpenSSH's own format ("BEGIN OPENSSH PRIVATE KEY") is not PEM and has to go
  # through :ssh_file.
  defp decode_openssh(pem) do
    case :ssh_file.decode(pem, :openssh_key_v1) do
      [{key, _attrs} | _] -> {:ok, key}
      _ -> :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp decode_pem(pem, passphrase) do
    case :public_key.pem_decode(pem) do
      [entry | _] -> decode_pem_entry(entry, passphrase)
      _ -> {:error, :invalid_private_key}
    end
  rescue
    _ -> {:error, :invalid_private_key}
  end

  defp decode_pem_entry(entry, passphrase) do
    key =
      case passphrase do
        value when is_binary(value) and value != "" ->
          :public_key.pem_entry_decode(entry, String.to_charlist(value))

        _ ->
          :public_key.pem_entry_decode(entry)
      end

    {:ok, key}
  rescue
    _ -> {:error, :invalid_private_key}
  end

  defp algorithm_supported?(algorithm, key) do
    to_string(algorithm) in algorithms_for(key)
  end

  defp algorithms_for(key) when is_tuple(key) and tuple_size(key) > 0 do
    case elem(key, 0) do
      :RSAPrivateKey -> ["ssh-rsa", "rsa-sha2-256", "rsa-sha2-512"]
      :DSAPrivateKey -> ["ssh-dss"]
      :ed_pri -> ed_algorithms(key)
      :ECPrivateKey -> ["ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521"]
      _ -> []
    end
  end

  defp algorithms_for(_key), do: []

  defp ed_algorithms(key) do
    case elem(key, 1) do
      :ed25519 -> ["ssh-ed25519"]
      :ed448 -> ["ssh-ed448"]
      _ -> []
    end
  end
end
