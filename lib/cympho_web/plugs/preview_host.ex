defmodule CymphoWeb.Plugs.PreviewHost do
  @moduledoc """
  Keeps untrusted runtime previews on their dedicated origin.

  The preview host serves only signed proxy-capability paths. Conversely, the
  proxy path is unavailable on the authenticated application origin. This
  prevents preview HTML or JavaScript from sharing the user's app cookies,
  CSRF token, or same-origin access.
  """

  @behaviour Plug
  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    preview_host = Application.get_env(:cympho, :preview_host)
    preview_path? = preview_proxy_path?(conn.path_info)
    on_preview_host? = is_binary(preview_host) and normalize_host(conn.host) == preview_host

    if (on_preview_host? and preview_path?) or (not on_preview_host? and not preview_path?) do
      conn
    else
      conn
      |> send_resp(:not_found, "Not found")
      |> halt()
    end
  end

  defp preview_proxy_path?(["api", "preview", _service_id, _token, "proxy" | _rest]), do: true
  defp preview_proxy_path?(_path), do: false

  defp normalize_host(host), do: host |> String.downcase() |> String.trim_trailing(".")
end
