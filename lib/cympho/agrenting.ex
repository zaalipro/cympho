defmodule Cympho.Agrenting do
  @moduledoc """
  Company-scoped Agrenting marketplace integration.
  """

  import Ecto.Query, warn: false

  alias Cympho.Agrenting.Client
  alias Cympho.Repo
  alias Cympho.Secrets
  alias Cympho.Secrets.Secret

  @api_key_secret "AGRENTING_API_KEY"
  @url_secret "AGRENTING_URL"
  @repo_access_token_secret "AGRENTING_REPO_ACCESS_TOKEN"

  def api_key_secret, do: @api_key_secret
  def url_secret, do: @url_secret
  def repo_access_token_secret, do: @repo_access_token_secret

  def configured?(company_id) when is_binary(company_id) do
    match?({:ok, _config}, company_config(company_id))
  end

  def configured?(_), do: false

  def company_config(company_id) when is_binary(company_id) do
    with {:ok, api_key} <- secret_value(company_id, @api_key_secret) do
      base_url =
        case secret_value(company_id, @url_secret) do
          {:ok, url} -> url
          _ -> Application.get_env(:cympho, :agrenting_url) || Client.default_base_url()
        end

      {:ok, %{"api_key" => api_key, "base_url" => base_url}}
    end
  end

  def company_config(_), do: {:error, :missing_company}

  def connection_status(company_id) when is_binary(company_id) do
    base_url = configured_base_url(company_id)

    %{
      connected?: configured?(company_id),
      api_key_present?: secret_present?(company_id, @api_key_secret),
      base_url: base_url,
      base_url_custom?: base_url != Client.default_base_url(),
      repo_token_present?: secret_present?(company_id, @repo_access_token_secret)
    }
  end

  def connection_status(_company_id) do
    %{
      connected?: false,
      api_key_present?: false,
      base_url: Client.default_base_url(),
      base_url_custom?: false,
      repo_token_present?: false
    }
  end

  def save_company_config(company_id, attrs) when is_binary(company_id) and is_map(attrs) do
    api_key = normalized_attr(attrs, "api_key")
    repo_access_token = normalized_attr(attrs, "repo_access_token")

    with {:ok, base_url} <- normalize_base_url(normalized_attr(attrs, "base_url")) do
      cond do
        api_key == "" and not secret_present?(company_id, @api_key_secret) ->
          {:error, :api_key_required}

        true ->
          with :ok <-
                 maybe_upsert_company_secret(
                   company_id,
                   @api_key_secret,
                   api_key,
                   api_key_description()
                 ),
               :ok <- save_base_url(company_id, base_url),
               :ok <-
                 maybe_upsert_company_secret(
                   company_id,
                   @repo_access_token_secret,
                   repo_access_token,
                   repo_access_token_description()
                 ) do
            {:ok, connection_status(company_id)}
          end
      end
    end
  end

  def save_company_config(_company_id, _attrs), do: {:error, :missing_company}

  def disconnect(company_id) when is_binary(company_id) do
    Enum.each([@api_key_secret, @url_secret, @repo_access_token_secret], fn key ->
      delete_company_secret(company_id, key)
    end)

    :ok
  end

  def disconnect(_company_id), do: :ok

  def test_connection(company_id) when is_binary(company_id) do
    with {:ok, config} <- company_config(company_id),
         {:ok, agents} <- Client.list_agents(config, %{"status" => "active"}) do
      {:ok, %{agent_count: length(List.wrap(agents)), checked_at: DateTime.utc_now()}}
    end
  end

  def test_connection(_company_id), do: {:error, :missing_company}

  def list_agents(company_id, filters \\ %{}) do
    with {:ok, config} <- company_config(company_id),
         {:ok, agents} <- Client.list_agents(config, filters) do
      {:ok, List.wrap(agents)}
    end
  end

  def get_agent(company_id, did) do
    with {:ok, config} <- company_config(company_id) do
      Client.get_agent(config, did)
    end
  end

  defp configured_base_url(company_id) do
    case secret_value(company_id, @url_secret) do
      {:ok, url} -> url
      _ -> Application.get_env(:cympho, :agrenting_url) || Client.default_base_url()
    end
  end

  defp normalized_attr(attrs, key) do
    attrs
    |> Map.get(key, Map.get(attrs, String.to_atom(key), ""))
    |> case do
      nil -> ""
      value -> value |> to_string() |> String.trim()
    end
  rescue
    ArgumentError -> ""
  end

  defp normalize_base_url(""), do: {:ok, Client.default_base_url()}

  defp normalize_base_url(value) do
    value = String.trim_trailing(value, "/")
    uri = URI.parse(value)

    if uri.scheme in ["http", "https"] and is_binary(uri.host) do
      {:ok, value}
    else
      {:error, :invalid_base_url}
    end
  end

  defp save_base_url(company_id, base_url) do
    if base_url == Client.default_base_url() do
      delete_company_secret(company_id, @url_secret)
    else
      upsert_company_secret(company_id, @url_secret, base_url, url_description())
    end
  end

  defp maybe_upsert_company_secret(_company_id, _key, "", _description), do: :ok

  defp maybe_upsert_company_secret(company_id, key, value, description) do
    upsert_company_secret(company_id, key, value, description)
  end

  defp upsert_company_secret(company_id, key, value, description) do
    attrs = %{
      "company_id" => company_id,
      "scope" => "company",
      "key" => key,
      "value" => value,
      "description" => description,
      "is_active" => true
    }

    result =
      case find_company_secret(company_id, key) do
        nil -> Secrets.create_secret(attrs)
        %Secret{} = secret -> Secrets.update_secret(secret, attrs)
      end

    case result do
      {:ok, _secret} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp delete_company_secret(company_id, key) do
    case find_company_secret(company_id, key) do
      nil ->
        :ok

      %Secret{} = secret ->
        case Secrets.delete_secret(secret) do
          {:ok, _secret} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp find_company_secret(company_id, key) do
    Secret
    |> where(company_id: ^company_id)
    |> where(scope: "company")
    |> where(key: ^key)
    |> where([secret], is_nil(secret.scope_id))
    |> order_by(desc: :is_active, desc: :version, desc: :updated_at)
    |> limit(1)
    |> Repo.one()
  end

  defp secret_present?(company_id, key) do
    match?({:ok, _value}, secret_value(company_id, key))
  end

  defp secret_value(company_id, key) do
    with {:ok, secret} <- Secrets.get_secret_by_key(company_id, key, scope: "company"),
         {:ok, value} <- Secrets.get_secret_value(secret.id),
         true <- is_binary(value) and String.trim(value) != "" do
      {:ok, String.trim(value)}
    else
      _ -> {:error, :not_configured}
    end
  end

  defp api_key_description, do: "Agrenting user API key for remote marketplace hires"
  defp url_description, do: "Agrenting marketplace base URL"
  defp repo_access_token_description, do: "Agrenting repo access token for push delivery"
end
