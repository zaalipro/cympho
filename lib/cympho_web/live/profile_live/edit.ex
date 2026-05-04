defmodule CymphoWeb.ProfileLive.Edit do
  use CymphoWeb, :live_view

  alias Cympho.Users

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Users.get_user(id) do
      {:ok, user} ->
        changeset = Users.change_user(user)

        {:ok,
         socket
         |> assign(:page_title, "Edit Profile")
         |> assign(:user, user)
         |> assign_form(changeset)}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "User not found")
         |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_event("save", %{"user" => user_params}, socket) do
    case Users.update_user(socket.assigns.user, user_params) do
      {:ok, user} ->
        {:noreply,
         socket
         |> put_flash(:info, "Profile updated successfully")
         |> push_navigate(to: ~p"/profile/#{user}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset =
      socket.assigns.user
      |> Users.change_user(user_params)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, :form, to_form(changeset))
  end
end
