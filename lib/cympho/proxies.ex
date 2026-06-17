defmodule Cympho.Proxies do
  @moduledoc """
  Company-scoped proxy profiles for swarm egress selection.

  Profiles keep connection metadata visible for operators while credentials stay
  encrypted. Swarm stores profile names/ids, not raw proxy URLs.
  """

  import Ecto.Changeset
  import Ecto.Query, warn: false

  alias Cympho.Proxies.ProxyProfile
  alias Cympho.Repo
  alias Cympho.Secrets.EncryptedStorage

  @tcp_timeout_ms 3_000

  def list_proxy_profiles(company_id) when is_binary(company_id) do
    ProxyProfile
    |> where(company_id: ^company_id)
    |> where(is_active: true)
    |> order_by([p], asc: p.name)
    |> Repo.all()
  end

  def list_proxy_profiles(_company_id), do: []

  def list_proxy_profiles_by_ids(company_id, ids) when is_binary(company_id) and is_list(ids) do
    ids = Enum.filter(ids, &is_binary/1)

    ProxyProfile
    |> where(company_id: ^company_id)
    |> where(is_active: true)
    |> where([p], p.id in ^ids)
    |> order_by([p], asc: p.name)
    |> Repo.all()
  end

  def list_proxy_profiles_by_ids(_company_id, _ids), do: []

  def proxy_profile_options(company_id) do
    company_id
    |> list_proxy_profiles()
    |> Enum.map(&{profile_label(&1), &1.id})
  end

  def get_company_proxy_profile(company_id, id) do
    query =
      ProxyProfile
      |> where(company_id: ^company_id)
      |> where(id: ^id)
      |> where(is_active: true)

    case Repo.one(query) do
      nil -> {:error, :not_found}
      profile -> {:ok, profile}
    end
  end

  def change_proxy_profile(%ProxyProfile{} = profile, attrs \\ %{}) do
    attrs = prepare_attrs(profile, attrs)

    profile
    |> ProxyProfile.changeset(attrs)
    |> maybe_add_proxy_url_error(attrs)
  end

  def create_proxy_profile(attrs) do
    attrs = prepare_attrs(%ProxyProfile{}, attrs)

    %ProxyProfile{}
    |> ProxyProfile.changeset(attrs)
    |> maybe_add_proxy_url_error(attrs)
    |> Repo.insert()
  end

  def update_proxy_profile(%ProxyProfile{} = profile, attrs) do
    attrs = prepare_attrs(profile, attrs)

    profile
    |> ProxyProfile.changeset(attrs)
    |> maybe_add_proxy_url_error(attrs)
    |> Repo.update()
  end

  def delete_proxy_profile(%ProxyProfile{} = profile) do
    profile
    |> ProxyProfile.changeset(%{is_active: false})
    |> Repo.update()
  end

  def test_proxy_profile(company_id, id) do
    with {:ok, profile} <- get_company_proxy_profile(company_id, id) do
      test_proxy_profile(profile)
    end
  end

  def test_proxy_profile(%ProxyProfile{} = profile) do
    started_at = System.monotonic_time(:millisecond)

    result =
      profile.host
      |> String.to_charlist()
      |> :gen_tcp.connect(profile.port, [:binary, active: false], @tcp_timeout_ms)

    checked_at = DateTime.utc_now() |> DateTime.truncate(:second)

    attrs =
      case result do
        {:ok, socket} ->
          :gen_tcp.close(socket)
          ping_ms = max(System.monotonic_time(:millisecond) - started_at, 0)

          %{
            last_status: "online",
            last_ping_ms: ping_ms,
            last_checked_at: checked_at,
            last_error: nil
          }

        {:error, reason} ->
          %{
            last_status: "offline",
            last_ping_ms: nil,
            last_checked_at: checked_at,
            last_error: format_error(reason)
          }
      end

    profile
    |> ProxyProfile.test_changeset(attrs)
    |> Repo.update()
  end

  def profile_label(%ProxyProfile{} = profile) do
    "#{profile.name} (#{profile.proxy_type}://#{profile.host}:#{profile.port})"
  end

  def profile_reference(%ProxyProfile{} = profile), do: profile.name

  defp prepare_attrs(%ProxyProfile{} = profile, attrs) do
    attrs =
      attrs
      |> stringify_keys()
      |> merge_proxy_url()
      |> encrypt_password(profile)

    attrs
    |> Map.update("proxy_type", nil, &normalize_proxy_type/1)
    |> Map.update("host", nil, &normalize_host/1)
    |> Map.update("name", nil, &normalize_name/1)
    |> Map.update("username", nil, &normalize_blank/1)
    |> Map.update("description", nil, &normalize_blank/1)
  end

  defp merge_proxy_url(%{"proxy_url" => url} = attrs) when is_binary(url) do
    case parse_proxy_url(url) do
      {:ok, parsed} -> Map.merge(attrs, parsed)
      :ignore -> attrs
      {:error, reason} -> Map.put(attrs, "proxy_url_error", reason)
    end
  end

  defp merge_proxy_url(attrs), do: attrs

  defp parse_proxy_url(url) do
    url = String.trim(url)

    if url == "" do
      :ignore
    else
      uri = URI.parse(url)
      type = normalize_proxy_type(uri.scheme)

      cond do
        type not in ProxyProfile.proxy_types() ->
          {:error, "Use http, https, socks4, or socks5 URLs."}

        uri.host in [nil, ""] ->
          {:error, "Proxy URL must include a host."}

        true ->
          username_password = parse_userinfo(uri.userinfo)

          {:ok,
           %{
             "proxy_type" => type,
             "host" => uri.host,
             "port" => uri.port || default_port(type)
           }
           |> Map.merge(username_password)}
      end
    end
  end

  defp parse_userinfo(nil), do: %{}

  defp parse_userinfo(userinfo) do
    case String.split(userinfo, ":", parts: 2) do
      [username, password] ->
        %{
          "username" => URI.decode_www_form(username),
          "password" => URI.decode_www_form(password)
        }

      [username] ->
        %{"username" => URI.decode_www_form(username)}
    end
  end

  defp default_port(type) when type in ["socks4", "socks5"], do: 1080
  defp default_port("https"), do: 443
  defp default_port(_type), do: 8080

  defp encrypt_password(%{"proxy_url_error" => reason} = attrs, _profile) do
    attrs
    |> Map.drop(["password"])
    |> Map.put("encrypted_password", nil)
    |> Map.put("_proxy_url_error", reason)
  end

  defp encrypt_password(attrs, %ProxyProfile{} = profile) do
    case Map.get(attrs, "password") do
      password when is_binary(password) and password != "" ->
        {:ok, encrypted} = EncryptedStorage.encrypt(password)

        attrs
        |> Map.drop(["password"])
        |> Map.put("encrypted_password", encrypted)

      _ ->
        attrs
        |> Map.drop(["password"])
        |> maybe_preserve_password(profile)
    end
  end

  defp maybe_add_proxy_url_error(changeset, %{"_proxy_url_error" => reason}) do
    add_error(changeset, :proxy_url, reason)
  end

  defp maybe_add_proxy_url_error(changeset, _attrs), do: changeset

  defp maybe_preserve_password(attrs, %ProxyProfile{encrypted_password: encrypted})
       when is_binary(encrypted) do
    Map.put_new(attrs, "encrypted_password", encrypted)
  end

  defp maybe_preserve_password(attrs, _profile), do: attrs

  defp normalize_proxy_type(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_proxy_type(value), do: value

  defp normalize_host(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()

  defp normalize_host(value), do: value

  defp normalize_name(value) when is_binary(value), do: String.trim(value)
  defp normalize_name(value), do: value

  defp normalize_blank(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_blank(value), do: value

  defp stringify_keys(%{} = attrs) do
    Map.new(attrs, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp stringify_keys(other), do: other

  defp format_error(:timeout), do: "Connection timed out"
  defp format_error(:nxdomain), do: "Host could not be resolved"
  defp format_error(:econnrefused), do: "Connection refused"
  defp format_error(reason), do: inspect(reason)
end
