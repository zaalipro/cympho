defmodule Cympho.Authentication do
  @moduledoc """
  Authentication context for managing agent API keys and JWT tokens.

  Provides functions for:
  - Creating and managing agent API keys
  - Generating JWT tokens for agent heartbeats
  - Validating credentials
  """

  import Ecto.Query, warn: false
  alias Cympho.Agents.{Agent, AgentApiKey}
  alias Cympho.Repo
  alias Cympho.AgentAuthJWT
  alias Cympho.HeartbeatEngine.Run

  @active_run_statuses ~w(pending queued running)
  @blocked_agent_statuses [:paused, :pending_approval, :terminated]
  @blocked_governance_statuses ["paused", "pending_approval", "terminated"]

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
  Revokes every API key issued to an agent.

  Termination uses hard revocation because it is permanent. Pausing and a
  pending governance decision leave key rows in place so an explicit resume
  can restore access without rotating credentials.
  """
  def revoke_agent_api_keys(agent_id) when is_binary(agent_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {count, _} =
      AgentApiKey
      |> where(
        [ak],
        ak.agent_id == ^agent_id and (is_nil(ak.expires_at) or ak.expires_at > ^now)
      )
      |> Repo.update_all(set: [expires_at: now, updated_at: now])

    {:ok, count}
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
  Authenticates a run-scoped agent JWT against current database state.

  A valid signature is not sufficient: the run must still be pending, queued,
  or running and its agent and company must exactly match the token claims.
  Paused, pending-approval, and terminated agents cannot start a new HTTP or
  WebSocket authentication, even during the short pause/cancellation race.

  Heartbeat run finalization is intentionally separate from this boundary:
  an already executing Orchestrator may still complete, fail, or cancel its
  run after an agent is paused without re-authenticating the agent credential.
  """
  def authenticate_heartbeat_token(token) do
    with {:ok, claims} <- AgentAuthJWT.verify_token(token),
         {:ok, agent_id} <- claim_uuid(claims, &AgentAuthJWT.get_agent_id/1),
         {:ok, run_id} <- claim_uuid(claims, &AgentAuthJWT.get_run_id/1),
         {:ok, company_id} <- claim_uuid(claims, &AgentAuthJWT.get_company_id/1),
         %Agent{} = agent <- Repo.get(Agent, agent_id),
         %Run{} = run <- Repo.get(Run, run_id),
         :ok <- validate_agent_credential_state(agent),
         :ok <- validate_run_scope(run, agent, company_id) do
      {:ok, %{agent: agent, run: run, claims: claims}}
    else
      nil -> {:error, :invalid_agent_jwt}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Authenticates a user with email and password.

  ## Returns
    - {:ok, user} on success
    - {:error, :invalid_credentials} on failure
  """
  def authenticate_user(email, password) do
    email = Cympho.Users.User.normalize_email(email)
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
    case authenticate_agent_api_key(plain_text_key) do
      {:ok, {_api_key, agent}} -> {:ok, agent}
      {:error, _reason} -> {:error, :invalid_api_key}
    end
  end

  @doc false
  def authenticate_agent_api_key(plain_text_key) when is_binary(plain_text_key) do
    key_hash = AgentApiKey.hash_api_key(plain_text_key)

    query =
      from(ak in AgentApiKey,
        where: ak.key_hash == ^key_hash,
        where: is_nil(ak.expires_at) or ak.expires_at > ^DateTime.utc_now(),
        preload: [:agent]
      )

    case Repo.one(query) do
      nil ->
        {:error, :invalid_api_key}

      %AgentApiKey{agent: %Agent{} = agent} = api_key ->
        with :ok <- validate_agent_credential_state(agent) do
          {:ok, {api_key, agent}}
        end
    end
  end

  def authenticate_agent_api_key(_plain_text_key), do: {:error, :invalid_api_key}

  defp validate_agent_credential_state(%Agent{status: status} = agent) do
    if status in @blocked_agent_statuses or
         agent.governance_status in @blocked_governance_statuses do
      {:error, :agent_inactive}
    else
      :ok
    end
  end

  defp validate_run_scope(%Run{} = run, %Agent{} = agent, company_id) do
    if run.status in @active_run_statuses and run.agent_id == agent.id and
         run.company_id == company_id and agent.company_id == company_id do
      :ok
    else
      {:error, :invalid_run_scope}
    end
  end

  defp claim_uuid(claims, extractor) do
    with {:ok, value} <- extractor.(claims),
         {:ok, uuid} <- Ecto.UUID.cast(value) do
      {:ok, uuid}
    else
      _ -> {:error, :invalid_agent_jwt}
    end
  end
end
