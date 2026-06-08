defmodule CymphoWeb.SettingsLive.Appearance do
  @moduledoc """
  Theme picker. Persists the choice to the current user (`Cympho.Themes` is the
  source of truth for valid ids) and pushes `set-theme` so the `phx:set-theme`
  client listener flips `<html data-theme>` live and mirrors it into the cookie.
  """
  use CymphoWeb, :live_view

  alias Cympho.Themes
  alias Cympho.Users

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Appearance")
     |> assign(:grouped, Themes.grouped())
     |> assign(:current_theme, current_theme(socket))}
  end

  @impl true
  def handle_event("set_theme", %{"theme" => id}, socket) do
    with true <- Themes.valid?(id),
         %{id: user_id} <- socket.assigns[:current_user],
         {:ok, user} <- Users.get_user(user_id),
         {:ok, _updated} <- Users.update_theme(user, id) do
      {:noreply,
       socket
       |> assign(:current_theme, id)
       |> push_event("set-theme", %{theme: id})}
    else
      _ -> {:noreply, put_flash(socket, :error, "Could not change theme.")}
    end
  end

  defp current_theme(socket) do
    case socket.assigns[:current_user] do
      %{theme: theme} when is_binary(theme) -> Themes.normalize(theme)
      _ -> Themes.default()
    end
  end
end
