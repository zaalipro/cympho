defmodule CymphoWeb.Components.NavRail do
  use Phoenix.Component

  attr :current_path, :string, required: true
  attr :collapsed, :boolean, default: false
  attr :rest, :global

  def nav_rail(assigns) do
    ~H"""
    <nav class="flex-1 py-4 px-3 space-y-1" {@rest}>
      <.nav_link
        to="/"
        label="Dashboard"
        icon={~s|<path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M3 12l2-2m0 0l7-7 7 7M5 10v10a1 1 0 001 1h3m10-11l2 2m-2-2v10a1 1 0 01-1 1h-3m-6 0a1 1 0 001-1v-4a1 1 0 011-1h2a1 1 0 011 1v4a1 1 0 001 1m-6 0h6"/>|}
        current_path={@current_path}
        collapsed={@collapsed}
      />
      <.nav_link
        to="/inbox"
        label="Inbox"
        icon={~s|<path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M20 13V6a2 2 0 00-2-2H6a2 2 0 00-2 2v7m16 0v5a2 2 0 01-2 2H6a2 2 0 01-2-2v-5m16 0h-2.586a1 1 0 00-.707.293l-2.414 2.414a1 1 0 01-.707.293h-3.172a1 1 0 01-.707-.293l-2.414-2.414A1 1 0 006.586 13H4"/>|}
        current_path={@current_path}
        collapsed={@collapsed}
      />
      <.nav_link
        to="/issues"
        label="Issues"
        icon={~s|<path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 5H7a2 2 0 00-2 2v12a2 2 0 002 2h10a2 2 0 002-2V7a2 2 0 00-2-2h-2M9 5a2 2 0 002 2h2a2 2 0 002-2M9 5a2 2 0 012-2h2a2 2 0 012 2m-3 7h3m-3 4h3m-6-4h.01M9 16h.01"/>|}
        current_path={@current_path}
        collapsed={@collapsed}
      />
      <.nav_link
        to="/projects"
        label="Projects"
        icon={~s|<path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M3 7v10a2 2 0 002 2h14a2 2 0 002-2V9a2 2 0 00-2-2h-6l-2-2H5a2 2 0 00-2 2z"/>|}
        current_path={@current_path}
        collapsed={@collapsed}
      />
      <.nav_link
        to="/agents"
        label="Agents"
        icon={~s|<path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 11c0 3.517-1.009 6.799-2.753 9.571m-3.44-2.04l.054-.09A13.916 13.916 0 008 11a4 4 0 118 0c0 1.017-.07 2.019-.203 3m-2.118 6.844A21.88 21.88 0 0015.171 17m3.839 1.132c.645-2.266.99-4.659.99-7.131A8 8 0 008 3.239c-4.828 4.596-5.212 11.611-.647 16.656A21.866 21.866 0 0012 21.942a21.866 21.866 0 003.99-.385M19.337 17.81a15.79 15.79 0 01-2.326 1.575"/>|}
        current_path={@current_path}
        collapsed={@collapsed}
      />
      <.nav_link
        to="/settings"
        label="Settings"
        icon={~s|<path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 002.573 1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0 001.066 2.573c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0 00-1.066 2.573c.94 1.543-.826 3.31-2.37 2.37a1.724 1.724 0 00-2.573 1.066c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0 00-2.573-1.066c-1.543.94-3.31-.826-2.37-2.37a1.724 1.724 0 00-1.066-2.573c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0 001.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065z"/><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"/>|}
        current_path={@current_path}
        collapsed={@collapsed}
      />
    </nav>
    """
  end

  defp nav_link(assigns) do
    ~H"""
    <.link
      navigate={@to}
      class={[
        "nav-item flex items-center gap-3 px-3 py-2.5 rounded-md text-sm font-510 transition-colors",
        "text-text-secondary hover:text-text-primary hover:bg-white/[0.04]",
        "active:bg-white/[0.08]",
        nav_active_class(@to, @current_path)
      ]}
      data-nav-path={@to}
    >
      <svg class="w-4 h-4 shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24">
        {@icon |> raw()}
      </svg>
      <span :if={!@collapsed} class="hidden md:inline">{@label}</span>
    </.link>
    """
  end

  defp nav_active_class(path, current_path) do
    if active_path?(path, current_path) do
      "text-text-primary bg-white/[0.06]"
    else
      ""
    end
  end

  defp active_path?("/", current_path), do: current_path == "/"
  defp active_path?(path, current_path), do: String.starts_with?(current_path, path)
end
