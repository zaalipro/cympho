defmodule CymphoWeb.CompanyImportLive do
  use CymphoWeb, :live_view
  alias Cympho.Companies

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Import Company")
      |> assign(:url, "")
      |> assign(:status, :idle)
      |> assign(:result, nil)
      |> assign(:error, nil)

    {:ok, socket}
  end

  @impl true
  def handle_event("update_url", %{"url" => url}, socket) do
    {:noreply, assign(socket, %{url: url, status: :idle, error: nil})}
  end

  def handle_event("import", %{"url" => url}, socket) do
    if url == "" do
      {:noreply, assign(socket, :error, "Please enter a URL")}
    else
      socket = assign(socket, status: :importing, error: nil)

      case fetch_and_import(url) do
        {:ok, result} ->
          {:noreply,
           socket
           |> assign(:status, :success)
           |> assign(:result, result)}

        {:error, reason} ->
          {:noreply,
           socket
           |> assign(:status, :error)
           |> assign(:error, reason)}
      end
    end
  end

  defp fetch_and_import(url) do
    case Finch.build(:get, url) |> Finch.request(Cympho.Finch) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        import_company(body)

      {:ok, %Finch.Response{status: status}} ->
        {:error, "Failed to fetch template: HTTP #{status}"}

      {:error, reason} ->
        {:error, "Failed to fetch template: #{inspect(reason)}"}
    end
  end

  defp import_company(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, data} -> import_company(data)
      {:error, reason} -> {:error, "Invalid JSON: #{reason}"}
    end
  end

  defp import_company(data) when is_map(data) do
    case Companies.import_company(data, slug_strategy: :suffix) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, "Import failed: #{inspect(reason)}"}
    end
  end
end
