defmodule Cympho.Secrets do
  import Ecto.Query, warn: false
  alias Ecto.Multi

  alias Cympho.Repo
  alias Cympho.Secrets.Secret
  alias Cympho.Secrets.EncryptedStorage

  @rotation_due_days 90
  @rotation_overdue_days 180

  def list_secrets(company_id, opts \\ []) do
    Secret
    |> where(company_id: ^company_id)
    |> where(is_active: true)
    |> maybe_filter(:scope, opts[:scope])
    |> maybe_filter(:scope_id, opts[:scope_id])
    |> order_by(asc: :key)
    |> Repo.all()
  end

  @doc """
  Returns non-sensitive rotation metadata for active secrets in a company.

  Rotation age is based on the active version row's `inserted_at`, so metadata
  edits do not reset the clock. Secret values are never decrypted or returned.
  """
  def rotation_inventory(company_id, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    company_id
    |> list_secrets(opts)
    |> Enum.map(&rotation_entry(&1, now, opts))
  end

  def rotation_summary(company_id, opts \\ []) do
    entries = rotation_inventory(company_id, opts)
    counts = Enum.frequencies_by(entries, & &1.status)

    %{
      total: length(entries),
      fresh: Map.get(counts, :fresh, 0),
      due_soon: Map.get(counts, :due_soon, 0),
      overdue: Map.get(counts, :overdue, 0),
      unknown: Map.get(counts, :unknown, 0),
      needs_rotation: Map.get(counts, :due_soon, 0) + Map.get(counts, :overdue, 0),
      by_scope: Enum.frequencies_by(entries, & &1.scope)
    }
  end

  def rotation_entry(%Secret{} = secret, now \\ DateTime.utc_now(), opts \\ []) do
    age_days = secret_age_days(secret, now)
    due_days = Keyword.get(opts, :due_days, @rotation_due_days)
    overdue_days = Keyword.get(opts, :overdue_days, @rotation_overdue_days)
    status = rotation_status(age_days, due_days, overdue_days)

    %{
      id: secret.id,
      key: secret.key,
      scope: secret.scope,
      scope_id: secret.scope_id,
      version: secret.version,
      rotated_at: secret.inserted_at,
      age_days: age_days,
      due_days: due_days,
      overdue_days: overdue_days,
      status: status,
      action_label: rotation_action_label(status)
    }
  end

  def list_secrets_page(company_id, opts \\ []) do
    Secret
    |> where(company_id: ^company_id)
    |> where(is_active: true)
    |> maybe_filter(:scope, opts[:scope])
    |> maybe_filter(:scope_id, opts[:scope_id])
    |> Cympho.Pagination.page(
      limit: Keyword.get(opts, :limit, 50),
      after: Keyword.get(opts, :after),
      cursor_fields: [{:key, :asc}, {:id, :asc}]
    )
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
      attrs =
        attrs
        |> stringify_keys()
        |> Map.drop(["value"])
        |> Map.put("encrypted_value", encrypted)

      %Secret{}
      |> Secret.changeset(attrs)
      |> Repo.insert()
    end
  end

  def update_secret(%Secret{} = secret, attrs) do
    attrs =
      case attrs[:value] || attrs["value"] do
        nil ->
          stringify_keys(attrs)

        plaintext ->
          {:ok, encrypted} = encrypt_value(plaintext)

          attrs
          |> stringify_keys()
          |> Map.drop(["value"])
          |> Map.put("encrypted_value", encrypted)
      end

    secret
    |> Secret.changeset(attrs)
    |> Repo.update()
  end

  # Normalize a map to use only string keys. Without this, callers that mix
  # atom and string keys (e.g. `%{scope: "x", "encrypted_value" => bin}`)
  # crash Ecto.Changeset.cast/4 with "expected params to be a map with atoms
  # or string keys, got a map with mixed keys".
  defp stringify_keys(%{} = attrs) do
    Map.new(attrs, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp stringify_keys(other), do: other

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
    case Repo.get(Secret, secret_id) do
      nil ->
        []

      secret ->
        Secret
        |> where(key: ^secret.key, company_id: ^secret.company_id)
        |> order_by(desc: :version)
        |> Repo.all()
    end
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

  defp secret_age_days(%Secret{inserted_at: nil}, _now), do: nil

  defp secret_age_days(%Secret{inserted_at: inserted_at}, now) do
    max(DateTime.diff(now, inserted_at, :day), 0)
  end

  defp rotation_status(nil, _due_days, _overdue_days), do: :unknown

  defp rotation_status(age_days, _due_days, overdue_days) when age_days >= overdue_days,
    do: :overdue

  defp rotation_status(age_days, due_days, _overdue_days) when age_days >= due_days, do: :due_soon
  defp rotation_status(_age_days, _due_days, _overdue_days), do: :fresh

  defp rotation_action_label(:overdue), do: "Rotate now"
  defp rotation_action_label(:due_soon), do: "Plan rotation"
  defp rotation_action_label(:fresh), do: "Current"
  defp rotation_action_label(:unknown), do: "Review"

  @doc """
  Lists active secrets applicable to an agent: company-scoped + agent-scoped.
  """
  def list_secrets_for_agent(agent_id) do
    case Cympho.Agents.get_agent(agent_id) do
      {:ok, agent} ->
        company_id = agent.company_id || get_company_id_from_config(agent.config)

        if company_id do
          Secret
          |> where([s], s.is_active == true)
          |> where(
            [s],
            (s.scope == "company" and s.company_id == ^company_id) or
              (s.scope == "instance" and s.company_id == ^company_id) or
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
