defmodule CymphoWeb.PreviewController do
  @moduledoc """
  Proxy controller for preview URLs.
  Routes requests to the appropriate runtime service based on the service ID.
  """
  use CymphoWeb, :controller

  alias Cympho.Workspaces
  alias Cympho.Workspaces.RuntimeService
  alias Cympho.Workspaces.PreviewUrl

  def proxy(conn, %{"service_id" => service_id}) do
    service = Workspaces.get_runtime_service!(service_id)
    proxy_to_service(conn, service)
  rescue
    Ecto.NoResultsError ->
      conn
      |> put_status(:not_found)
      |> json(%{error: "Runtime service not found"})
  end

  defp proxy_to_service(conn, %RuntimeService{} = service) do
    if service.status == "running" && service.port do
      target_url = PreviewUrl.get_target_url(service)
      proxy_request(conn, target_url)
    else
      conn
      |> put_status(:service_unavailable)
      |> json(%{error: "Service is not running", status: service.status})
    end
  end

  defp proxy_request(conn, target_url) do
    path = Enum.join(conn.path_info -- ["preview", hd(conn.path_info)], "/")
    query_string = conn.query_string

    full_url =
      case {path, query_string} do
        {"", ""} -> target_url
        {"", _} -> "#{target_url}?#{query_string}"
        {_, ""} -> "#{target_url}/#{path}"
        {_, _} -> "#{target_url}/#{path}?#{query_string}"
      end

    headers = Enum.map(conn.req_headers, fn {k, v} -> {k, v} end)

    case Finch.build(conn.method, full_url, headers, conn.body) |> Finch.request(Cympho.Finch, []) do
      {:ok, response} ->
        filtered_headers = Enum.filter(response.headers, fn {k, _} ->
          k in ["content-type", "content-length", "cache-control", "etag"]
        end)

        conn
        |> put_status(response.status)
        |> merge_resp_headers(filtered_headers)
        |> send_resp(response.status, response.body)

      {:error, reason} ->
        conn
        |> put_status(:bad_gateway)
        |> json(%{error: "Failed to proxy request", reason: inspect(reason)})
    end
  end

  @doc """
  Get preview URL for a runtime service.
  """
  def show(conn, %{"service_id" => service_id}) do
    service = Workspaces.get_runtime_service!(service_id)
    base_url = get_base_url(conn)
    preview_url = PreviewUrl.generate_preview_url(service, base_url)

    json(conn, %{
      data: %{
        id: service.id,
        service_name: service.service_name,
        status: service.status,
        port: service.port,
        preview_url: preview_url,
        target_url: if(service.status == "running", do: PreviewUrl.get_target_url(service))
      }
    })
  rescue
    Ecto.NoResultsError ->
      conn
      |> put_status(:not_found)
      |> json(%{error: "Runtime service not found"})
  end

  @doc """
  List previewable services for an execution workspace.
  """
  def index(conn, %{"execution_workspace_id" => ew_id}) do
    services = Workspaces.list_runtime_services(ew_id)
    base_url = get_base_url(conn)

    previews =
      Enum.map(services, fn service ->
        %{
          id: service.id,
          service_name: service.service_name,
          status: service.status,
          port: service.port,
          preview_url: PreviewUrl.generate_preview_url(service, base_url)
        }
      end)

    json(conn, %{data: previews})
  end

  defp get_base_url(conn) do
    scheme = if conn.scheme == :https, do: "https", else: "http"
    host = conn.host
    port = if (conn.scheme == :https && conn.port == 443) || (conn.scheme == :http && conn.port == 80), do: nil, else: conn.port

    base = "#{scheme}://#{host}"
    if port, do: "#{base}:#{port}", else: base
  end
end
