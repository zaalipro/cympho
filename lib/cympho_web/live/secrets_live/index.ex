defmodule CymphoWeb.SecretsLive.Index do
  use CymphoWeb, :live_view
  alias Cympho.Secrets
  alias Cympho.Secrets.Secret

  @impl true
  def mount(%{"company_id" => company_id}, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Secrets Management")
      |> assign(:company_id, company_id)
      |> assign(:secrets, [])
      |> assign(:selected_secret, nil)
      |> assign(:show_form, false)
      |> assign(:form_mode, :create)
      |> assign(:versions, [])
      |> assign(:show_versions, false)
      |> load_secrets()

    {:ok, socket}
  end

  def mount(_, session, socket) do
    # Try to get company_id from current company
    company_id = get_current_company_id(socket)

    if company_id do
      mount(%{"company_id" => company_id}, session, socket)
    else
      {:ok, assign(socket, :page_title, "Secrets Management")}
    end
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info({CymphoWeb.SecretsLive.FormComponent, {:saved, _result}}, socket) do
    socket =
      socket
      |> put_flash(:info, "Secret saved successfully")
      |> assign(:show_form, false)
      |> load_secrets()

    {:noreply, socket}
  end

  @impl true
  def handle_event("show_create_form", _, socket) do
    changeset = Secret.changeset(%Secret{}, %{})

    socket =
      socket
      |> assign(:show_form, true)
      |> assign(:form_mode, :create)
      |> assign(:changeset, changeset)
      |> assign(:selected_secret, nil)

    {:noreply, socket}
  end

  def handle_event("show_edit_form", %{"id" => id}, socket) do
    {:ok, secret} = Secrets.get_secret(id)
    changeset = Secret.changeset(secret, %{})

    socket =
      socket
      |> assign(:show_form, true)
      |> assign(:form_mode, :edit)
      |> assign(:changeset, changeset)
      |> assign(:selected_secret, secret)

    {:noreply, socket}
  end

  def handle_event("show_versions", %{"id" => id}, socket) do
    versions = Secrets.list_secret_versions(id)

    socket =
      socket
      |> assign(:selected_secret, id)
      |> assign(:versions, versions)
      |> assign(:show_versions, true)

    {:noreply, socket}
  end

  def handle_event("hide_form", _, socket) do
    socket =
      socket
      |> assign(:show_form, false)
      |> assign(:changeset, nil)

    {:noreply, socket}
  end

  def handle_event("hide_versions", _, socket) do
    socket =
      socket
      |> assign(:show_versions, false)
      |> assign(:versions, [])

    {:noreply, socket}
  end

  def handle_event("save", %{"secret" => secret_params}, socket) do
    company_id = socket.assigns.company_id

    secret_params = Map.put(secret_params, "company_id", company_id)

    result =
      case socket.assigns.form_mode do
        :create -> Secrets.create_secret(secret_params)
        :edit -> Secrets.update_secret(socket.assigns.selected_secret, secret_params)
      end

    case result do
      {:ok, _secret} ->
        socket =
          socket
          |> put_flash(:info, "Secret saved successfully")
          |> assign(:show_form, false)
          |> load_secrets()

        {:noreply, socket}

      {:error, changeset} ->
        socket =
          socket
          |> put_flash(:error, "Failed to save secret")
          |> assign(:changeset, changeset)

        {:noreply, socket}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case Secrets.get_secret(id) do
      {:ok, secret} ->
        case Secrets.delete_secret(secret) do
          {:ok, _} ->
            socket =
              socket
              |> put_flash(:info, "Secret deleted successfully")
              |> load_secrets()

            {:noreply, socket}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete secret")}
        end

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Secret not found")}
    end
  end

  def handle_event("rotate", %{"id" => id}, socket) do
    case Secrets.get_secret(id) do
      {:ok, secret} ->
        # For rotation, we'd typically show a modal to enter new value
        # For now, we'll open the edit form
        changeset = Secret.changeset(secret, %{})

        socket =
          socket
          |> assign(:show_form, true)
          |> assign(:form_mode, :rotate)
          |> assign(:changeset, changeset)
          |> assign(:selected_secret, secret)

        {:noreply, socket}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Secret not found")}
    end
  end

  defp load_secrets(socket) do
    company_id = socket.assigns.company_id
    secrets = Secrets.list_secrets(company_id)
    assign(socket, :secrets, secrets)
  end

  defp get_current_company_id(socket) do
    case socket.assigns do
      %{current_company: %{id: id}} -> id
      %{current_user: %{company_id: id}} -> id
      _ -> nil
    end
  end

  defp scope_badge_class("company"), do: "bg-purple-500/20 text-purple-400"
  defp scope_badge_class("instance"), do: "bg-blue-500/20 text-blue-400"
  defp scope_badge_class("agent"), do: "bg-green-500/20 text-green-400"
  defp scope_badge_class("project"), do: "bg-yellow-500/20 text-yellow-400"
  defp scope_badge_class(_), do: "bg-gray-500/20 text-gray-400"

  defp format_scope("company"), do: "Company"
  defp format_scope("instance"), do: "Instance"
  defp format_scope("agent"), do: "Agent"
  defp format_scope("project"), do: "Project"
  defp format_scope(scope), do: String.capitalize(scope)
end
