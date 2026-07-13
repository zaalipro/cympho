defmodule CymphoWeb.SettingsLive.Profile do
  @moduledoc """
  Account → Profile tab of the Settings hub. Edits the current user's name and
  email, reusing `Cympho.Users.change_user/2` + `update_user/2` (the same path
  as `ProfileLive.Edit`). `current_user` in the socket is a lightweight map, so
  the full `%User{}` is loaded by id before building the changeset.
  """
  use CymphoWeb, :live_view

  alias Cympho.Users

  @impl true
  def mount(_params, _session, socket) do
    case Users.get_user(socket.assigns.current_user.id) do
      {:ok, user} ->
        {:ok,
         socket
         |> assign(:page_title, "Profile")
         |> assign(:user, user)
         |> assign_form(Users.change_user(user))}

      _ ->
        {:ok,
         socket
         |> put_flash(:error, "Could not load your profile.")
         |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_event("validate", %{"user" => params}, socket) do
    changeset =
      socket.assigns.user
      |> Users.change_user(params)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"user" => params}, socket) do
    case Users.update_user(socket.assigns.user, params) do
      {:ok, user} ->
        {:noreply,
         socket
         |> assign(:user, user)
         |> assign_form(Users.change_user(user))
         |> put_flash(:info, "Profile updated.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, :form, to_form(changeset))
  end

  defp profile_initial(%{name: name}) when is_binary(name) and name != "" do
    name |> String.trim() |> String.first() |> to_string() |> String.upcase()
  end

  defp profile_initial(%{email: email}) when is_binary(email) and email != "" do
    email |> String.first() |> to_string() |> String.upcase()
  end

  defp profile_initial(_user), do: "?"
end
