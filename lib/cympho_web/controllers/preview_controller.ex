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
    case scoped_runtime_service(conn, service_id) do
      {:ok, service} ->
        proxy_to_service(conn, service)

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Runtime service not found"})
    end
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

    case Finch.build(conn.method, full_url, headers, conn.body)
         |> Finch.request(Cympho.Finch, []) do
      {:ok, response} ->
        filtered_headers =
          Enum.filter(response.headers, fn {k, _} ->
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
    case scoped_runtime_service(conn, service_id) do
      {:ok, service} ->
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

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Runtime service not found"})
    end
  end

  @doc """
  List previewable services for an execution workspace.
  """
  def index(conn, %{"id" => ew_id}) do
    case Workspaces.get_company_execution_workspace(company_id(conn), ew_id) do
      {:ok, execution_workspace} ->
        services = Workspaces.list_runtime_services(execution_workspace.id)
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

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Execution workspace not found"})
    end
  end

  defp scoped_runtime_service(conn, service_id) do
    Workspaces.get_company_runtime_service(company_id(conn), service_id)
  end

  defp company_id(conn), do: conn.assigns.current_company.id

  defp get_base_url(conn) do
    scheme = if conn.scheme == :https, do: "https", else: "http"
    host = conn.host

    port =
      if (conn.scheme == :https && conn.port == 443) || (conn.scheme == :http && conn.port == 80),
        do: nil,
        else: conn.port

    base = "#{scheme}://#{host}"
    if port, do: "#{base}:#{port}", else: base
  end
end
