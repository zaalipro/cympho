defmodule Cympho.Authentication do
  @moduledoc """
  Authentication context for managing agent API keys and JWT tokens.

  Provides functions for:
  - Creating and managing agent API keys
  - Generating JWT tokens for agent heartbeats
  - Validating credentials
  """

  import Ecto.Query, warn: false
  alias Cympho.Repo
  alias Cympho.Agents.Agent
  alias Cympho.Agents.AgentApiKey
  alias Cympho.AgentAuthJWT

  @doc """
  Creates a new API key for an agent.

  ## Parameters
    - agent_id: The ID of the agent
    - name: A descriptive name for the API key
    - attrs: Optional attributes (e.g., expires_at)

  ## Returns
    - {:ok, {api_key, plain_text_key}} on success
    - {:error, changeset} on failure

  ## Example
      {:ok, {api_key, plain_text_key}} = Authentication.create_agent_api_key(agent_id, "Production Key")
      # plain_text_key is only returned once - store it securely!
  """
  def create_agent_api_key(agent_id, name, attrs \\ %{}) do
    plain_text_key = AgentApiKey.generate_api_key()
    key_hash = AgentApiKey.hash_api_key(plain_text_key)

    attrs =
      attrs
      |> Map.put(:name, name)
      |> Map.put(:agent_id, agent_id)
      |> Map.put(:key_hash, key_hash)

    %AgentApiKey{}
    |> AgentApiKey.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, api_key} -> {:ok, {api_key, plain_text_key}}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Lists all API keys for an agent.
  """
  def list_agent_api_keys(agent_id) do
    from(ak in AgentApiKey, where: ak.agent_id == ^agent_id, order_by: [desc: ak.inserted_at])
    |> Repo.all()
  end

  @doc """
  Gets an API key by ID.
  """
  def get_agent_api_key(id) do
    Repo.get(AgentApiKey, id)
  end

  @doc """
  Deletes an API key.
  """
  def delete_agent_api_key(%AgentApiKey{} = api_key) do
    Repo.delete(api_key)
  end

  @doc """
  Generates a JWT token for an agent heartbeat.

  ## Parameters
    - agent_id: The ID of the agent
    - run_id: The ID of the current run
    - company_id: The ID of the company

  ## Returns
    - {:ok, jwt_token} on success
    - {:error, reason} on failure
  """
  def generate_heartbeat_token(agent_id, run_id, company_id) do
    AgentAuthJWT.generate_token(agent_id, run_id, company_id)
  end

  @doc """
  Verifies a JWT token and returns the claims.

  ## Returns
    - {:ok, claims} on success
    - {:error, reason} on failure
  """
  def verify_heartbeat_token(token) do
    AgentAuthJWT.verify_token(token)
  end

  @doc """
  Authenticates a user with email and password.

  ## Returns
    - {:ok, user} on success
    - {:error, :invalid_credentials} on failure
  """
  def authenticate_user(email, password) do
    query = from(u in Cympho.Users.User, where: u.email == ^email)

    case Repo.one(query) do
      nil ->
        Argon2.no_user_verify()
        {:error, :invalid_credentials}

      user ->
        if Cympho.Users.User.valid_password?(user, password) do
          {:ok, user}
        else
          {:error, :invalid_credentials}
        end
    end
  end

  @doc """
  Registers a new user with a password.

  ## Returns
    - {:ok, user} on success
    - {:error, changeset} on failure
  """
  def register_user(attrs) do
    %Cympho.Users.User{}
    |> Cympho.Users.User.registration_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Validates an API key and returns the associated agent.

  ## Returns
    - {:ok, agent} on success
    - {:error, :invalid_api_key} on failure
  """
  def validate_api_key(plain_text_key) do
    key_hash = AgentApiKey.hash_api_key(plain_text_key)

    query =
      from(ak in AgentApiKey,
        where: ak.key_hash == ^key_hash,
        where: is_nil(ak.expires_at) or ak.expires_at > ^DateTime.utc_now(),
        preload: [:agent])

    case Repo.one(query) do
      nil -> {:error, :invalid_api_key}
      api_key -> {:ok, api_key.agent}
    end
  end
end
