defmodule Cympho.Secrets.EncryptedStorageTest do
  use ExUnit.Case, async: true

  alias Cympho.Secrets.EncryptedStorage

  @test_key :crypto.strong_rand_bytes(32)

  setup do
    original = Application.get_env(:cympho, :encryption_key)
    Application.put_env(:cympho, :encryption_key, @test_key)

    on_exit(fn ->
      if original do
        Application.put_env(:cympho, :encryption_key, original)
      else
        Application.delete_env(:cympho, :encryption_key)
      end
    end)

    :ok
  end

  describe "encrypt/1 and decrypt/1" do
    test "encrypts and decrypts a plaintext string" do
      plaintext = "my-super-secret-api-key"

      assert {:ok, encrypted} = EncryptedStorage.encrypt(plaintext)
      assert is_binary(encrypted)
      assert encrypted != plaintext

      assert {:ok, decrypted} = EncryptedStorage.decrypt(encrypted)
      assert decrypted == plaintext
    end

    test "produces different ciphertexts for same plaintext (random IV)" do
      plaintext = "same-input"

      assert {:ok, encrypted1} = EncryptedStorage.encrypt(plaintext)
      assert {:ok, encrypted2} = EncryptedStorage.encrypt(plaintext)

      assert encrypted1 != encrypted2

      assert {:ok, decrypted1} = EncryptedStorage.decrypt(encrypted1)
      assert {:ok, decrypted2} = EncryptedStorage.decrypt(encrypted2)
      assert decrypted1 == plaintext
      assert decrypted2 == plaintext
    end

    test "handles empty string" do
      plaintext = ""

      assert {:ok, encrypted} = EncryptedStorage.encrypt(plaintext)
      assert {:ok, decrypted} = EncryptedStorage.decrypt(encrypted)
      assert decrypted == plaintext
    end

    test "handles unicode content" do
      plaintext = "秘密の鍵🔑"

      assert {:ok, encrypted} = EncryptedStorage.encrypt(plaintext)
      assert {:ok, decrypted} = EncryptedStorage.decrypt(encrypted)
      assert decrypted == plaintext
    end

    test "returns error for invalid ciphertext" do
      assert {:error, :invalid_ciphertext} = EncryptedStorage.decrypt(<<1, 2, 3>>)
    end

    test "returns error for tampered ciphertext" do
      assert {:ok, encrypted} = EncryptedStorage.encrypt("original")

      tampered = :binary.encode_unsigned(:binary.decode_unsigned(encrypted) + 1)
      assert {:error, _} = EncryptedStorage.decrypt(tampered)
    end
  end
end
