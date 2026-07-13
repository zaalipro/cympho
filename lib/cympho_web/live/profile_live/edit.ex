defmodule CymphoWeb.ProfileLive.Edit do
  use CymphoWeb, :live_view

  alias Cympho.Users

  @impl true
  def render(assigns) do
    ~H"""
    <.page size="content" class="ember-aurora">
      <div class="relative z-[1]">
        <.header>
          <div class="min-w-0">
            <span class="ember-eyebrow">Account</span>
            <h1 class="ember-ink mt-4 font-serif text-[clamp(30px,4.5vw,44px)] font-510 leading-[1.08] tracking-[-0.02em]">
              Edit profile
            </h1>
            <p class="mt-2 text-[15px] leading-6 text-text-tertiary">
              Update how you appear across every company.
            </p>
          </div>
          <:actions>
            <.app_link
              navigate={~p"/profile/#{@user}"}
              class="rounded-lg border border-border bg-button px-4 py-2 text-sm font-510 text-text-secondary transition-colors hover:bg-button-hover hover:text-text-primary"
            >
              Cancel
            </.app_link>
          </:actions>
        </.header>

        <section class="ember-glass overflow-hidden">
          <div class="border-b border-white/10 px-5 py-4">
            <p class="font-serif text-[13px] font-510 italic tracking-[0.02em] text-brand/90">
              Identity
            </p>
            <h2 class="mt-1 text-lg font-590 text-text-primary">Personal details</h2>
          </div>

          <.simple_form
            for={@form}
            phx-change="validate"
            phx-submit="save"
            class="space-y-5 p-5 sm:p-6"
          >
            <.input field={@form[:name]} label="Name" required placeholder="Your name" />
            <.input
              field={@form[:email]}
              type="email"
              label="Email"
              required
              placeholder="you@example.com"
            />

            <:actions>
              <div class="flex items-center justify-end gap-2 border-t border-white/10 pt-4">
                <.app_link
                  navigate={~p"/profile/#{@user}"}
                  class="rounded-lg px-4 py-2 text-sm font-510 text-text-tertiary transition-colors hover:bg-surface-hover hover:text-text-primary"
                >
                  Cancel
                </.app_link>
                <.button type="submit" variant="primary" class="cta-glow">Save changes</.button>
              </div>
            </:actions>
          </.simple_form>
        </section>
      </div>
    </.page>
    """
  end

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
