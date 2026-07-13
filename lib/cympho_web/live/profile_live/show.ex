defmodule CymphoWeb.ProfileLive.Show do
  use CymphoWeb, :live_view

  alias Cympho.{Users, Repo}

  @impl true
  def render(assigns) do
    ~H"""
    <.page size="content" class="ember-aurora">
      <div class="relative z-[1]">
        <.header>
          <div class="min-w-0">
            <span class="ember-eyebrow">Profile</span>
            <h1 class="ember-ink mt-4 font-serif text-[clamp(30px,4.5vw,44px)] font-510 leading-[1.08] tracking-[-0.02em]">
              {@user.name}
            </h1>
            <p class="mt-2 text-[15px] leading-6 text-text-tertiary">{@user.email}</p>
          </div>
          <:actions>
            <.app_link
              navigate={~p"/profile/#{@user}/edit"}
              class="inline-flex items-center gap-2 cta-glow rounded-button bg-brand px-4 py-2 text-sm font-510 text-on-primary transition-colors hover:bg-accent"
            >
              <.icon name="hero-pencil-square-mini" class="h-4 w-4" /> Edit profile
            </.app_link>
          </:actions>
        </.header>

        <section class="ember-glass overflow-hidden">
          <div class="border-b border-white/10 px-5 py-4">
            <p class="font-serif text-[13px] font-510 italic tracking-[0.02em] text-brand/90">
              Membership
            </p>
            <h2 class="mt-1 text-lg font-590 text-text-primary">Companies</h2>
          </div>

          <div
            :if={@memberships == []}
            class="px-5 py-10 text-center text-sm text-text-tertiary"
          >
            Not a member of any company yet.
          </div>

          <ul :if={@memberships != []} class="divide-y divide-white/[0.06]">
            <li
              :for={membership <- @memberships}
              class="flex items-center justify-between gap-3 px-5 py-4 transition-colors hover:bg-subtle hover:shadow-[inset_2px_0_0_0_var(--color-primary)]"
            >
              <div class="min-w-0">
                <p class="truncate text-sm font-590 text-text-primary">
                  {membership.company.name}
                </p>
                <p class="mt-0.5 text-xs text-text-tertiary">
                  <code class="rounded bg-black/20 px-1.5 py-0.5">{membership.company.slug}</code>
                </p>
              </div>
              <span class="shrink-0 rounded-full border border-brand/20 bg-brand/10 px-2.5 py-1 text-xs font-510 capitalize text-brand">
                {membership.role}
              </span>
            </li>
          </ul>
        </section>

        <section class="mt-6 rounded-xl border border-red-500/20 bg-red-500/[0.05] p-5">
          <p class="font-serif text-[13px] font-510 italic tracking-[0.02em] text-red-300">
            Danger zone
          </p>
          <div class="mt-2 flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
            <p class="max-w-xl text-sm leading-5 text-text-tertiary">
              Permanently delete this account and remove it from every company. This cannot be undone.
            </p>
            <button
              type="button"
              phx-click="delete_account"
              data-confirm={"Delete #{@user.name}'s account? This permanently removes the user and cannot be undone."}
              class="inline-flex shrink-0 items-center gap-2 rounded-lg border border-red-500/25 bg-red-500/10 px-4 py-2 text-sm font-510 text-red-300 transition-colors hover:bg-red-500/15"
            >
              <.icon name="hero-trash-mini" class="h-4 w-4" /> Delete account
            </button>
          </div>
        </section>
      </div>
    </.page>
    """
  end

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Users.get_user(id) do
      {:ok, user} ->
        user = Repo.preload(user, memberships: :company)

        {:ok,
         socket
         |> assign(:page_title, "Profile: #{user.name}")
         |> assign(:user, user)
         |> assign(:memberships, user.memberships)}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "User not found")
         |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_event("delete_account", _params, socket) do
    case Users.delete_user(socket.assigns.user) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Account deleted successfully")
         |> push_navigate(to: ~p"/")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete account")}
    end
  end
end
