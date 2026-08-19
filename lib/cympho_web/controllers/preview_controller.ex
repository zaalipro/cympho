defmodule CymphoWeb.PreviewController do
  @moduledoc """
  Proxy controller for preview URLs.
  Routes requests to the appropriate runtime service based on the service ID.
  """
  use CymphoWeb, :controller

  alias Cympho.Workspaces
  alias Cympho.Workspaces.RuntimeService
  alias Cympho.Workspaces.PreviewUrl

  @max_response_bytes 16 * 1024 * 1024
  @max_response_header_count 100
  @max_response_header_bytes 64 * 1024
  @forwarded_req_headers ~w(accept accept-language if-modified-since if-none-match range user-agent)
  @forwarded_resp_headers ~w(accept-ranges cache-control content-range content-type etag last-modified)

  def proxy(conn, %{"service_id" => service_id, "token" => token}) do
    case capability_preview_service(service_id, token) do
      {:ok, service} ->
        proxy_to_service(conn, service)

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Runtime service not found"})
    end
  end

  defp proxy_to_service(conn, %RuntimeService{} = service) do
    case PreviewUrl.get_target_url(service) do
      nil ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Proxy target address is not allowed"})

      _target_url when service.status != "running" ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "Service is not running", status: service.status})

      target_url ->
        proxy_request(conn, target_url)
    end
  end

  defp proxy_request(conn, target_url) do
    path = proxy_path(conn)
    query_string = conn.query_string

    full_url =
      case {path, query_string} do
        {"", ""} -> target_url
        {"", _} -> "#{target_url}?#{query_string}"
        {_, ""} -> "#{target_url}/#{path}"
        {_, _} -> "#{target_url}/#{path}?#{query_string}"
      end

    request = Finch.build(conn.method, full_url, filter_req_headers(conn.req_headers), "")

    case request_preview(request) do
      {:ok, response} ->
        conn
        |> merge_resp_headers(filter_resp_headers(response.headers))
        |> send_resp(response.status, response.body)

      {:error, :response_too_large} ->
        conn
        |> put_status(:bad_gateway)
        |> json(%{error: "Preview response exceeds the allowed size"})

      {:error, _reason} ->
        conn
        |> put_status(:bad_gateway)
        |> json(%{error: "Failed to proxy request"})
    end
  end

  defp request_preview(request) do
    initial = %{
      status: nil,
      headers: [],
      header_count: 0,
      header_bytes: 0,
      body: [],
      size: 0,
      overflow: nil
    }

    reducer = fn
      {:status, status}, state ->
        {:cont, %{state | status: status}}

      {:headers, headers}, state ->
        header_count = state.header_count + length(headers)
        header_bytes = state.header_bytes + response_header_bytes(headers)

        cond do
          header_count > @max_response_header_count or
              header_bytes > @max_response_header_bytes ->
            {:halt,
             %{
               state
               | overflow: :headers,
                 header_count: header_count,
                 header_bytes: header_bytes
             }}

          oversized_content_length?(headers) ->
            {:halt, %{state | overflow: :body}}

          true ->
            {:cont,
             %{
               state
               | headers: state.headers ++ headers,
                 header_count: header_count,
                 header_bytes: header_bytes
             }}
        end

      {:data, chunk}, state ->
        size = state.size + byte_size(chunk)

        if size > @max_response_bytes do
          {:halt, %{state | overflow: :body}}
        else
          {:cont, %{state | body: [chunk | state.body], size: size}}
        end

      {:trailers, _trailers}, state ->
        {:cont, state}
    end

    case Finch.stream_while(request, Cympho.Finch, initial, reducer,
           receive_timeout: 15_000,
           request_timeout: 30_000
         ) do
      {:ok, %{overflow: :headers}} ->
        {:error, :response_headers_too_large}

      {:ok, %{overflow: :body}} ->
        {:error, :response_too_large}

      {:ok, %{status: status, headers: headers, body: body}} when is_integer(status) ->
        {:ok,
         %{
           status: status,
           headers: headers,
           body: body |> Enum.reverse() |> IO.iodata_to_binary()
         }}

      {:ok, _state} ->
        {:error, :invalid_upstream_response}

      {:error, reason, _state} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp response_header_bytes(headers) do
    Enum.reduce(headers, 0, fn {name, value}, total ->
      total + byte_size(name) + byte_size(value) + 4
    end)
  end

  defp oversized_content_length?(headers) do
    Enum.any?(headers, fn {name, value} ->
      String.downcase(name) == "content-length" and
        case Integer.parse(value) do
          {length, ""} -> length > @max_response_bytes
          _ -> false
        end
    end)
  end

  defp proxy_path(conn) do
    case conn.params["path"] do
      path when is_list(path) ->
        Enum.join(path, "/")

      path when is_binary(path) and path != "" ->
        path

      _ ->
        case conn.path_info do
          ["api", "preview", _id, _token, "proxy" | rest] -> Enum.join(rest, "/")
          _ -> ""
        end
    end
  end

  defp filter_req_headers(headers) do
    Enum.filter(headers, fn {name, _} -> String.downcase(name) in @forwarded_req_headers end)
  end

  defp filter_resp_headers(headers) do
    headers
    |> Enum.map(fn {name, value} -> {String.downcase(name), value} end)
    |> Enum.filter(fn {name, _} -> name in @forwarded_resp_headers end)
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
            target_url: PreviewUrl.get_target_url(service)
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

  defp capability_preview_service(service_id, token) do
    with {:ok, preview_ref} <- PreviewUrl.verify_capability(service_id, token),
         {:ok, service} <- Workspaces.get_preview_service(service_id, preview_ref) do
      {:ok, service}
    else
      _ -> {:error, :not_found}
    end
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
