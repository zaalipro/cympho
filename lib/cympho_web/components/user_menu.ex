defmodule CymphoWeb.Components.UserMenu do
  @moduledoc """
  The rail's account row (r3 `div.acct`): a closed menu holding only personal
  items (N2): Profile, Appearance, the Simple/Advanced switch, Help, Keyboard
  shortcuts and Sign out. Every page lives under its destination in the Main
  navigation, so there is no "More" block here.
  """
  use Phoenix.Component

  import CymphoWeb.Components.R3, only: [r3_icon: 1]

  use Phoenix.VerifiedRoutes,
    endpoint: CymphoWeb.Endpoint,
    router: CymphoWeb.Router

  @dev Mix.env() == :dev

  attr :user, :any, default: nil

  def user_menu(assigns) do
    assigns = assign(assigns, :initials, initials(assigns.user))

    ~H"""
    <div class="acct">
      <details>
        <summary>
          <span class="av" aria-hidden="true">{@initials}</span>
          <span class="acct-name">{if @user, do: @user.name || @user.email, else: "Guest"}</span>
          <.r3_icon name="i-chev-updown" />
        </summary>
        <div class="menu up">
          <%= if @user do %>
            <.link navigate={~p"/settings/profile"} data-runtime-menu-close>Profile</.link>
            <.link navigate={~p"/settings/appearance"} data-runtime-menu-close>
              Appearance
            </.link>
            <div
              class="menu-mode"
              data-ui-mode-switch
              data-sidebar-ui-mode-switch
              data-sidebar-ui-mode-toggle
              role="group"
              aria-label="Interface mode"
              aria-describedby="interface-mode-help"
            >
              <button
                type="button"
                data-ui-mode-option="simple"
                data-active="true"
                aria-pressed="true"
                aria-controls="main-content"
                title="Simple view — guided essentials"
                class="ui-mode-option"
              >
                Simple
              </button>
              <button
                type="button"
                data-ui-mode-option="advanced"
                data-active="false"
                aria-pressed="false"
                aria-controls="main-content"
                title="Advanced view — full controls and diagnostics"
                class="ui-mode-option"
              >
                Advanced
              </button>
            </div>
            <.link navigate={~p"/docs"} data-runtime-menu-close>Help</.link>
            <button type="button" data-shortcuts-btn data-runtime-menu-close>
              Keyboard shortcuts
            </button>
            <.link href={~p"/logout"} method="delete">Sign out</.link>
          <% else %>
            <.link href={~p"/login"}>Sign in</.link>
            <.link :if={dev?()} href="/dev/login">Dev owner</.link>
            <.link navigate={~p"/docs"}>Help</.link>
          <% end %>
        </div>
      </details>
    </div>
    """
  end

  defp initials(nil), do: "?"

  defp initials(%{name: name}) when is_binary(name) and name != "" do
    name
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map(&String.first/1)
    |> Enum.join()
    |> String.upcase()
  end

  defp initials(%{email: email}) when is_binary(email) do
    email |> String.first() |> String.upcase()
  end

  defp initials(_), do: "?"

  defp dev?, do: @dev
end
