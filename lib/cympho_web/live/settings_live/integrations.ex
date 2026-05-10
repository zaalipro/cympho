defmodule CymphoWeb.SettingsLive.Integrations do
  use CymphoWeb, :live_view

  alias Cympho.Agrenting

  @impl true
  def mount(_params, _session, socket) do
    status = load_agrenting_status(socket)

    {:ok,
     socket
     |> assign(:page_title, "Integrations")
     |> assign(:agrenting_status, status)
     |> assign(:agrenting_form, agrenting_form(status))
     |> assign(:agrenting_test_result, nil)}
  end

  @impl true
  def handle_event("save_agrenting", %{"agrenting" => params}, socket) do
    case Agrenting.save_company_config(current_company_id(socket), params) do
      {:ok, status} ->
        {:noreply,
         socket
         |> assign(:agrenting_status, status)
         |> assign(:agrenting_form, agrenting_form(status))
         |> assign(:agrenting_test_result, nil)
         |> put_flash(:info, "Agrenting connection saved")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, agrenting_error(reason))}
    end
  end

  def handle_event("test_agrenting", _params, socket) do
    result = Agrenting.test_connection(current_company_id(socket))

    socket =
      case result do
        {:ok, %{agent_count: count}} ->
          socket
          |> assign(:agrenting_test_result, result)
          |> put_flash(:info, "Agrenting connected. Found #{count} marketplace agents.")

        {:error, reason} ->
          socket
          |> assign(:agrenting_test_result, result)
          |> put_flash(:error, "Agrenting test failed: #{agrenting_error(reason)}")
      end

    {:noreply, socket}
  end

  def handle_event("disconnect_agrenting", _params, socket) do
    :ok = Agrenting.disconnect(current_company_id(socket))
    status = load_agrenting_status(socket)

    {:noreply,
     socket
     |> assign(:agrenting_status, status)
     |> assign(:agrenting_form, agrenting_form(status))
     |> assign(:agrenting_test_result, nil)
     |> put_flash(:info, "Agrenting disconnected")}
  end

  defp current_company_id(%{assigns: %{current_company: %{id: id}}}), do: id
  defp current_company_id(_socket), do: nil

  defp load_agrenting_status(socket) do
    socket
    |> current_company_id()
    |> Agrenting.connection_status()
  end

  defp agrenting_form(status) do
    to_form(
      %{
        "api_key" => "",
        "base_url" => status.base_url,
        "repo_access_token" => ""
      },
      as: :agrenting
    )
  end

  defp agrenting_connected?(status), do: Map.get(status, :connected?, false)
  defp api_key_present?(status), do: Map.get(status, :api_key_present?, false)
  defp custom_base_url?(status), do: Map.get(status, :base_url_custom?, false)
  defp repo_token_present?(status), do: Map.get(status, :repo_token_present?, false)

  defp connection_badge_class(status) do
    if agrenting_connected?(status) do
      "border-success/25 bg-success/10 text-success"
    else
      "border-border bg-surface text-text-tertiary"
    end
  end

  defp connection_badge_label(status) do
    if agrenting_connected?(status), do: "Connected", else: "Not connected"
  end

  defp present_label(true), do: "Stored"
  defp present_label(false), do: "Not stored"

  defp test_result_label(nil), do: nil
  defp test_result_label({:ok, %{agent_count: count}}), do: "Test passed. #{count} agents found."
  defp test_result_label({:error, reason}), do: "Test failed. #{agrenting_error(reason)}"

  defp agrenting_error(:api_key_required), do: "Enter an Agrenting API key to connect."
  defp agrenting_error(:invalid_base_url), do: "Base URL must start with http:// or https://."
  defp agrenting_error(:missing_company), do: "Select a company before connecting Agrenting."
  defp agrenting_error(:not_configured), do: "Add an Agrenting API key first."

  defp agrenting_error(%Ecto.Changeset{} = changeset) do
    changeset.errors
    |> Enum.map(fn {field, {message, _opts}} -> "#{field} #{message}" end)
    |> Enum.join(", ")
    |> case do
      "" -> "Agrenting settings could not be saved."
      message -> message
    end
  end

  defp agrenting_error(_reason), do: "Agrenting did not accept the connection."
end
