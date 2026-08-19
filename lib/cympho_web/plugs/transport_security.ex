defmodule CymphoWeb.Plugs.TransportSecurity do
  @moduledoc """
  Enforces production HTTPS without blindly trusting forwarded headers.

  Only `x-forwarded-proto` is honored, and only when the immediate peer is an
  explicitly trusted reverse proxy. Redirects always use the configured
  application host, never a request or forwarded host header.
  """

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    config = if opts == [], do: config(), else: opts

    if Keyword.get(config, :force_ssl, false) do
      conn
      |> rewrite_forwarded_proto(config)
      |> then(&Plug.SSL.call(&1, ssl_options(config, &1)))
    else
      conn
    end
  end

  # Called by Phoenix's compile-time force_ssl plug, which runs before socket
  # dispatch. Returning true is safe only for an HTTPS assertion from the
  # configured immediate proxy; the regular plug rewrites the scheme later.
  def exclude_from_builtin_ssl?(conn) do
    config = config()

    not Keyword.get(config, :force_ssl, false) or preview_host_request?(conn) or
      trusted_forwarded_https?(conn, config)
  end

  def configured_host do
    config()
    |> Keyword.fetch!(:host)
  end

  @doc """
  Returns whether an address belongs to the configured immediate-proxy allowlist.

  Entries may be exact IPv4/IPv6 tuples or `{network_address, prefix_length}`
  CIDR tuples produced by `config/runtime.exs`.
  """
  def trusted_peer?(address) do
    trusted_peer?(address, Keyword.get(config(), :trusted_proxy_ips, []))
  end

  def trusted_peer?(address, trusted_proxy_ips) when is_list(trusted_proxy_ips) do
    Enum.any?(trusted_proxy_ips, &trusted_proxy_entry?(address, &1))
  end

  def trusted_peer?(_address, _trusted_proxy_ips), do: false

  defp rewrite_forwarded_proto(conn, config) do
    if trusted_forwarded_https?(conn, config) do
      Plug.RewriteOn.call(conn, [:x_forwarded_proto])
    else
      conn
    end
  end

  defp trusted_forwarded_https?(conn, config) do
    trusted_peer?(conn.remote_ip, Keyword.get(config, :trusted_proxy_ips, [])) and
      Plug.Conn.get_req_header(conn, "x-forwarded-proto") == ["https"]
  end

  defp trusted_proxy_entry?(address, address), do: valid_ip?(address)

  defp trusted_proxy_entry?(address, {network, prefix}) when is_integer(prefix) do
    with {:ok, segment_bits, address_bits} <- ip_layout(address),
         {:ok, ^segment_bits, ^address_bits} <- ip_layout(network),
         true <- prefix in 0..address_bits do
      shift = address_bits - prefix

      Bitwise.bsr(ip_to_integer(address, segment_bits), shift) ==
        Bitwise.bsr(ip_to_integer(network, segment_bits), shift)
    else
      _ -> false
    end
  end

  defp trusted_proxy_entry?(_address, _entry), do: false

  defp valid_ip?(address), do: match?({:ok, _, _}, ip_layout(address))

  defp ip_layout(address) when is_tuple(address) and tuple_size(address) == 4 do
    if valid_segments?(address, 255), do: {:ok, 8, 32}, else: :error
  end

  defp ip_layout(address) when is_tuple(address) and tuple_size(address) == 8 do
    if valid_segments?(address, 65_535), do: {:ok, 16, 128}, else: :error
  end

  defp ip_layout(_address), do: :error

  defp valid_segments?(address, maximum) do
    address
    |> Tuple.to_list()
    |> Enum.all?(&(is_integer(&1) and &1 in 0..maximum))
  end

  defp ip_to_integer(address, segment_bits) do
    address
    |> Tuple.to_list()
    |> Enum.reduce(0, fn segment, value ->
      value
      |> Bitwise.bsl(segment_bits)
      |> Bitwise.bor(segment)
    end)
  end

  defp ssl_options(config, conn) do
    host =
      if preview_host_request?(conn) do
        Application.fetch_env!(:cympho, :preview_host)
      else
        Keyword.fetch!(config, :host)
      end

    host
    |> then(fn host ->
      Plug.SSL.init(
        host: host,
        hsts: true,
        expires: 31_536_000,
        exclude: []
      )
    end)
  end

  defp preview_host_request?(conn) do
    case Application.get_env(:cympho, :preview_host) do
      host when is_binary(host) ->
        String.downcase(String.trim_trailing(conn.host, ".")) == host

      _ ->
        false
    end
  end

  defp config, do: Application.get_env(:cympho, :transport_security, [])
end
