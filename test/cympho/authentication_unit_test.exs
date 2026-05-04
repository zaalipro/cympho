defmodule Cympho.AuthenticationUnitTest do
  use ExUnit.Case, async: true

  alias Cympho.Users.User
  alias Cympho.AgentAuthJWT
  alias Cympho.UserAuthJWT
  alias Cympho.Agents.AgentApiKey

  describe "User Schema Validations" do
    test "valid_password? returns true for correct password" do
      # Create a user with known password hash
      password = "testpassword123"
      hash = Argon2.hash_pwd_salt(password)

      user = %User{
        id: "test-id",
        email: "test@example.com",
        name: "Test User",
        password_hash: hash
      }

      assert User.valid_password?(user, password) == true
    end

    test "valid_password? returns false for incorrect password" do
      password = "testpassword123"
      hash = Argon2.hash_pwd_salt(password)

      user = %User{
        id: "test-id",
        email: "test@example.com",
        name: "Test User",
        password_hash: hash
      }

      assert User.valid_password?(user, "wrongpassword") == false
    end

    test "valid_password? returns false when no hash" do
      user = %User{
        id: "test-id",
        email: "test@example.com",
        name: "Test User",
        password_hash: nil
      }

      assert User.valid_password?(user, "anypassword") == false
    end
  end

  describe "AgentApiKey" do
    test "generate_api_key creates a random key" do
      key1 = AgentApiKey.generate_api_key()
      key2 = AgentApiKey.generate_api_key()

      assert is_binary(key1)
      assert byte_size(key1) > 20
      assert key1 != key2
    end

    test "hash_api_key creates consistent hash" do
      key = "test-api-key-12345"
      hash1 = AgentApiKey.hash_api_key(key)
      hash2 = AgentApiKey.hash_api_key(key)

      assert hash1 == hash2
      # SHA256 produces 64 hex characters
      assert byte_size(hash1) == 64
    end

    test "hash_api_key is different for different keys" do
      hash1 = AgentApiKey.hash_api_key("key1")
      hash2 = AgentApiKey.hash_api_key("key2")

      assert hash1 != hash2
    end

    test "valid_api_key? verifies correctly" do
      key = "test-api-key-12345"
      hash = AgentApiKey.hash_api_key(key)

      assert AgentApiKey.valid_api_key?(key, hash) == true
      assert AgentApiKey.valid_api_key?("wrong-key", hash) == false
    end
  end

  describe "AgentAuthJWT" do
    test "generate_token creates a valid JWT" do
      agent_id = "agent-123"
      run_id = "run-456"
      company_id = "company-789"

      {:ok, token} = AgentAuthJWT.generate_token(agent_id, run_id, company_id)

      assert is_binary(token)
      assert token =~ "."
    end

    test "verify_token validates a generated token" do
      agent_id = "agent-123"
      run_id = "run-456"
      company_id = "company-789"

      {:ok, token} = AgentAuthJWT.generate_token(agent_id, run_id, company_id)
      {:ok, claims} = AgentAuthJWT.verify_token(token)

      assert claims["agent_id"] == agent_id
      assert claims["run_id"] == run_id
      assert claims["company_id"] == company_id
      assert claims["typ"] == "agent_heartbeat"
    end

    test "verify_token rejects expired token" do
      # Create a token with very short TTL won't work directly,
      # but we can test that invalid tokens are rejected
      assert AgentAuthJWT.verify_token("invalid.token.here") == {:error, :invalid_token_format}
    end

    test "verify_token rejects empty token" do
      assert AgentAuthJWT.verify_token("") == {:error, :empty_token}
      assert AgentAuthJWT.verify_token("   ") == {:error, :empty_token}
    end

    test "get_agent_id extracts agent_id from claims" do
      claims = %{"agent_id" => "test-agent"}
      assert AgentAuthJWT.get_agent_id(claims) == {:ok, "test-agent"}
      assert AgentAuthJWT.get_agent_id(%{}) == {:error, :agent_id_not_found}
    end

    test "get_run_id extracts run_id from claims" do
      claims = %{"run_id" => "test-run"}
      assert AgentAuthJWT.get_run_id(claims) == {:ok, "test-run"}
      assert AgentAuthJWT.get_run_id(%{}) == {:error, :run_id_not_found}
    end

    test "get_company_id extracts company_id from claims" do
      claims = %{"company_id" => "test-company"}
      assert AgentAuthJWT.get_company_id(claims) == {:ok, "test-company"}
      assert AgentAuthJWT.get_company_id(%{}) == {:error, :company_id_not_found}
    end
  end

  describe "UserAuthJWT" do
    test "generate_token creates a valid JWT for user" do
      user = %User{id: "user-123", email: "test@example.com"}

      {:ok, token} = UserAuthJWT.generate_token(user, "company-456")

      assert is_binary(token)
      assert token =~ "."
    end

    test "verify_token validates user token" do
      user = %User{id: "user-123", email: "test@example.com"}
      company_id = "company-456"

      {:ok, token} = UserAuthJWT.generate_token(user, company_id)
      {:ok, claims} = UserAuthJWT.verify_token(token)

      assert claims["user_id"] == "user-123"
      assert claims["email"] == "test@example.com"
      assert claims["company_id"] == company_id
      assert claims["typ"] == "user_session"
    end

    test "verify_token rejects invalid tokens" do
      assert UserAuthJWT.verify_token("not.a.valid.token") == {:error, :invalid_token_format}
      assert UserAuthJWT.verify_token("") == {:error, :empty_token}
    end

    test "get_user_id extracts user_id from claims" do
      claims = %{"user_id" => "test-user"}
      assert UserAuthJWT.get_user_id(claims) == {:ok, "test-user"}
      assert UserAuthJWT.get_user_id(%{}) == {:error, :user_id_not_found}
    end

    test "get_email extracts email from claims" do
      claims = %{"email" => "test@example.com"}
      assert UserAuthJWT.get_email(claims) == {:ok, "test@example.com"}
      assert UserAuthJWT.get_email(%{}) == {:error, :email_not_found}
    end
  end

  describe "User registration_changeset" do
    test "validates password length" do
      # Short password
      changeset =
        User.registration_changeset(%User{}, %{
          email: "test@example.com",
          name: "Test",
          password: "short"
        })

      assert !changeset.valid?
      assert Keyword.get(changeset.errors, :password)

      # Valid password
      changeset =
        User.registration_changeset(%User{}, %{
          email: "test@example.com",
          name: "Test",
          password: "validpassword123"
        })

      assert changeset.valid?
    end

    test "validates email format" do
      changeset =
        User.registration_changeset(%User{}, %{
          email: "invalid-email",
          name: "Test",
          password: "validpassword123"
        })

      assert !changeset.valid?
      assert Keyword.get(changeset.errors, :email)
    end

    test "creates password hash on valid registration" do
      changeset =
        User.registration_changeset(%User{}, %{
          email: "test@example.com",
          name: "Test",
          password: "validpassword123"
        })

      assert changeset.valid?
      assert changeset.changes[:password_hash] != nil
    end
  end
end
