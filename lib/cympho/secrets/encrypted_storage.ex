defmodule Cympho.Secrets.EncryptedStorage do
  @moduledoc false

  @cipher :aes_256_gcm
  @iv_length 12
  @tag_length 16

  def encrypt(plaintext) when is_binary(plaintext) do
    key = get_key()
    iv = :crypto.strong_rand_bytes(@iv_length)

    case :crypto.crypto_one_time_aead(@cipher, key, iv, plaintext, <<>>, true) do
      {ciphertext, tag} ->
        {:ok, iv <> tag <> ciphertext}

      error ->
        {:error, error}
    end
  end

  def decrypt(encrypted) when is_binary(encrypted) do
    key = get_key()

    if byte_size(encrypted) < @iv_length + @tag_length do
      {:error, :invalid_ciphertext}
    else
      <<iv::binary-size(@iv_length), tag::binary-size(@tag_length), ciphertext::binary>> =
        encrypted

      case :crypto.crypto_one_time_aead(@cipher, key, iv, ciphertext, <<>>, tag, false) do
        plaintext when is_binary(plaintext) ->
          {:ok, plaintext}

        error ->
          {:error, error}
      end
    end
  end

  defp get_key do
    key =
      Application.get_env(:cympho, :encryption_key) ||
        raise ":cympho, :encryption_key is not configured"

    if byte_size(key) != 32 do
      raise ":encryption_key must be exactly 32 bytes (256 bits)"
    end

    key
  end
end
