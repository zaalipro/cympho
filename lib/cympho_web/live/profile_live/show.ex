defmodule CymphoWeb.ProfileLive.Show do
  use CymphoWeb, :live_view

  alias Cympho.{Users, Companies, Repo}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Users.get_user(id) do
      {:ok, user} ->
        user = Repo.preload(user, [:company_memberships])

        memberships =
          Enum.map(user.company_memberships, fn mem ->
            case Companies.get_company(mem.company_id) do
              {:ok, company} -> Map.put(mem, :company, company)
              _ -> mem
            end
          end)

        {:ok,
         socket
         |> assign(:page_title, "Profile: #{user.username}")
         |> assign(:user, user)
         |> assign(:memberships, memberships)}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "User not found")
         |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :show, _params) do
    socket
    |> assign(:page_title, "Profile: #{socket.assigns.user.username}")
  end

  defp apply_action(socket, :edit, _params) do
    socket
    |> assign(:page_title, "Edit Profile")
  end

  @impl true
  def handle_event("delete_account", _params, socket) do
    case Users.delete_user(socket.assigns.user) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Account deleted successfully")
         |> push_navigate(to: ~p"/")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete account")}
    end
  end
end
