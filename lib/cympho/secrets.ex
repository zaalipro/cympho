defmodule Cympho.Secrets do
  import Ecto.Query, warn: false
  alias Ecto.Multi

  alias Cympho.Repo
  alias Cympho.Secrets.Secret
  alias Cympho.Secrets.EncryptedStorage

  def list_secrets(company_id, opts \\ []) do
    Secret
    |> where(company_id: ^company_id)
    |> where(is_active: true)
    |> maybe_filter(:scope, opts[:scope])
    |> maybe_filter(:scope_id, opts[:scope_id])
    |> order_by(asc: :key)
    |> Repo.all()
  end

  def get_secret!(id), do: Repo.get!(Secret, id)

  def get_secret(id) do
    case Repo.get(Secret, id) do
      nil -> {:error, :not_found}
      secret -> {:ok, secret}
    end
  end

  def get_secret_value!(id) do
    secret = Repo.get!(Secret, id)

    case EncryptedStorage.decrypt(secret.encrypted_value) do
      {:ok, plaintext} -> {:ok, plaintext}
      {:error, reason} -> raise "Failed to decrypt secret: #{inspect(reason)}"
    end
  end

  def get_secret_value(id) do
    with {:ok, secret} <- get_secret(id),
         {:ok, plaintext} <- EncryptedStorage.decrypt(secret.encrypted_value) do
      {:ok, plaintext}
    end
  end

  def get_secret_by_key(company_id, key, opts \\ []) do
    query =
      Secret
      |> where(company_id: ^company_id)
      |> where(key: ^key)
      |> where(is_active: true)

    query =
      if opts[:scope] do
        where(query, scope: ^opts[:scope])
      else
        query
      end

    query =
      if opts[:scope_id] do
        where(query, scope_id: ^opts[:scope_id])
      else
        query
      end

    case Repo.one(query) do
      nil -> {:error, :not_found}
      secret -> {:ok, secret}
    end
  end

  def create_secret(attrs) do
    with {:ok, encrypted} <- encrypt_value(attrs[:value] || attrs["value"]) do
      attrs = Map.drop(attrs, [:value, "value"]) |> Map.put(:encrypted_value, encrypted)

      %Secret{}
      |> Secret.changeset(attrs)
      |> Repo.insert()
    end
  end

  def update_secret(%Secret{} = secret, attrs) do
    attrs =
      case attrs[:value] || attrs["value"] do
        nil ->
          attrs

        plaintext ->
          {:ok, encrypted} = encrypt_value(plaintext)
          attrs |> Map.drop([:value, "value"]) |> Map.put(:encrypted_value, encrypted)
      end

    secret
    |> Secret.changeset(attrs)
    |> Repo.update()
  end

  def rotate_secret(%Secret{} = secret, new_value) do
    with {:ok, encrypted} <- encrypt_value(new_value) do
      new_version = secret.version + 1

      Multi.new()
      |> Multi.update(
        :deactivate_old,
        Secret.changeset(secret, %{is_active: false})
      )
      |> Multi.insert(:create_new, fn _ ->
        Secret.changeset(%Secret{}, %{
          company_id: secret.company_id,
          scope: secret.scope,
          scope_id: secret.scope_id,
          key: secret.key,
          encrypted_value: encrypted,
          version: new_version,
          description: secret.description
        })
      end)
      |> Repo.transaction()
    end
  end

  def delete_secret(%Secret{} = secret) do
    secret
    |> Secret.changeset(%{is_active: false})
    |> Repo.update()
  end

  def list_secret_versions(secret_id) do
    Secret
    |> where([s], s.key in fragment(
      "(SELECT ? FROM secrets WHERE id = ?)",
      select([s], s.key),
      ^secret_id
    ))
    |> where(company_id: fragment(
      "(SELECT company_id FROM secrets WHERE id = ?)",
      ^secret_id
    ))
    |> order_by(desc: :version)
    |> Repo.all()
  end

  def list_active_secret_values(company_id, opts \\ []) do
    list_secrets(company_id, opts)
    |> Enum.flat_map(fn secret ->
      case EncryptedStorage.decrypt(secret.encrypted_value) do
        {:ok, plaintext} -> [plaintext]
        {:error, _} -> []
      end
    end)
  end

  defp encrypt_value(nil), do: {:error, :value_required}

  defp encrypt_value(plaintext) when is_binary(plaintext) do
    EncryptedStorage.encrypt(plaintext)
  end

  @doc """
  Lists active secrets applicable to an agent: company-scoped + agent-scoped.
  """
  def list_secrets_for_agent(agent_id) do
    case Cympho.Agents.get_agent(agent_id) do
      {:ok, agent} ->
        company_id = get_company_id_from_config(agent.config)

        if company_id do
          Secret
          |> where([s], s.is_active == true)
          |> where(
            [s],
            (s.scope == "company" and s.company_id == ^company_id) or
              (s.scope == "agent" and s.scope_id == ^agent_id)
          )
          |> order_by([s], asc: s.key)
          |> Repo.all()
        else
          []
        end

      {:error, _} ->
        []
    end
  end

  @doc """
  Resolves secrets as environment variables for injection into agent workspaces.
  Returns a map of key -> decrypted value.
  """
  def resolve_env_for_agent(agent_id) do
    list_secrets_for_agent(agent_id)
    |> Enum.reduce(%{}, fn secret, acc ->
      case EncryptedStorage.decrypt(secret.encrypted_value) do
        {:ok, plaintext} -> Map.put(acc, secret.key, plaintext)
        {:error, _} -> acc
      end
    end)
  end

  defp get_company_id_from_config(%{"company_id" => id}), do: id
  defp get_company_id_from_config(_), do: nil

  defp maybe_filter(query, _field, nil), do: query

  defp maybe_filter(query, field, value), do: where(query, [s], field(s, ^field) == ^value)
end
