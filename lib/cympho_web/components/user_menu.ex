defmodule CymphoWeb.Components.UserMenu do
  @moduledoc """
  Bottom-of-sidebar user pill that opens a popover menu with the
  overflow nav (Org / Approvals / Costs / Activity / Workspaces /
  Plugins / Skills / Adapters / Tool traces), search, shortcuts,
  settings.

  Pairs with the `UserMenu` JS hook in app.js for click-outside
  dismissal and escape handling.
  """
  use Phoenix.Component

  use Phoenix.VerifiedRoutes,
    endpoint: CymphoWeb.Endpoint,
    router: CymphoWeb.Router

  attr :user, :any, default: nil
  attr :current_path, :string, default: "/"

  def user_menu(assigns) do
    assigns = assign(assigns, :initials, initials(assigns.user))

    ~H"""
    <div id="user-menu" phx-hook="UserMenu" class="relative">
      <button
        type="button"
        data-user-menu-trigger
        aria-haspopup="menu"
        aria-expanded="false"
        class={[
          "w-full flex items-center gap-2.5 px-2 py-2 rounded-lg",
          "text-text-secondary hover:bg-surface-hover hover:text-text-primary",
          "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand/40 transition-colors"
        ]}
      >
        <span class="flex h-7 w-7 shrink-0 items-center justify-center rounded-full bg-brand/15 text-[11px] font-590 text-brand">
          {@initials}
        </span>
        <span class="flex-1 truncate text-left text-[13px] font-510">
          {if @user, do: @user.name || @user.email, else: "Guest"}
        </span>
        <span class="hero-ellipsis-horizontal-mini w-4 h-4 text-text-quaternary"></span>
      </button>

      <div
        data-user-menu-popover
        role="menu"
        class={[
          "hidden absolute bottom-full left-0 right-0 mb-2 z-50 rounded-xl",
          "bg-surface-2 border border-hairline shadow-elevated overflow-hidden"
        ]}
      >
        <div :if={@user} class="px-3 py-2.5 border-b border-hairline">
          <p class="text-sm font-590 text-text-primary truncate">{@user.name || "Account"}</p>
          <p class="text-xs text-text-quaternary truncate">{@user.email}</p>
        </div>

        <div class="py-1">
          <p class="px-3 pt-1.5 pb-0.5 text-[10px] font-590 uppercase tracking-[0.08em] text-text-quaternary">
            More
          </p>
          <.menu_link
            to={~p"/org-chart"}
            icon="hero-share-mini"
            current={@current_path}
            label="Org chart"
          />
          <.menu_link
            to={~p"/approvals"}
            icon="hero-check-circle-mini"
            current={@current_path}
            label="Approvals"
          />
          <.menu_link
            to={~p"/costs"}
            icon="hero-currency-dollar-mini"
            current={@current_path}
            label="Costs"
          />
          <.menu_link
            to={~p"/activity"}
            icon="hero-bolt-mini"
            current={@current_path}
            label="Activity"
          />
          <.menu_link
            to={~p"/workspaces"}
            icon="hero-rectangle-stack-mini"
            current={@current_path}
            label="Workspaces"
          />
          <.menu_link
            to={~p"/plugins"}
            icon="hero-puzzle-piece-mini"
            current={@current_path}
            label="Plugins"
          />
          <.menu_link
            to={~p"/skills"}
            icon="hero-academic-cap-mini"
            current={@current_path}
            label="Skills"
          />
          <.menu_link
            to={~p"/adapters"}
            icon="hero-cog-6-tooth-mini"
            current={@current_path}
            label="Adapters"
          />
          <.menu_link
            to={~p"/tool-call-traces"}
            icon="hero-magnifying-glass-mini"
            current={@current_path}
            label="Tool traces"
          />
        </div>

        <div class="py-1 border-t border-hairline">
          <button
            type="button"
            data-action="open-command-palette"
            class={menu_row_class(false)}
            role="menuitem"
          >
            <span class="hero-magnifying-glass-mini w-4 h-4 text-text-tertiary group-hover:text-text-primary">
            </span>
            <span class="flex-1 text-left">Search</span>
            <kbd class="kbd">⌘K</kbd>
          </button>
          <button
            type="button"
            data-action="open-shortcuts"
            class={menu_row_class(false)}
            role="menuitem"
          >
            <span class="hero-command-line-mini w-4 h-4 text-text-tertiary group-hover:text-text-primary">
            </span>
            <span class="flex-1 text-left">Keyboard shortcuts</span>
            <kbd class="kbd">?</kbd>
          </button>
          <.menu_link
            to={~p"/settings"}
            icon="hero-cog-6-tooth-mini"
            current={@current_path}
            label="Settings"
          />
        </div>
      </div>
    </div>
    """
  end

  attr :to, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :current, :string, required: true

  defp menu_link(assigns) do
    active? = active?(assigns.to, assigns.current)
    assigns = assign(assigns, :active?, active?)

    ~H"""
    <.link navigate={@to} class={menu_row_class(@active?)} role="menuitem">
      <span class={[@icon, "w-4 h-4 text-text-tertiary group-hover:text-text-primary"]}></span>
      <span class="flex-1 text-left">{@label}</span>
    </.link>
    """
  end

  defp menu_row_class(active?) do
    [
      "group flex w-full items-center gap-2.5 px-3 py-1.5 text-[13px] font-510 transition-colors",
      "text-text-secondary hover:bg-surface-3 hover:text-text-primary",
      active? && "bg-surface-3 text-text-primary"
    ]
  end

  defp active?(path, current),
    do: current == path or String.starts_with?(current || "", path <> "/")

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
end
