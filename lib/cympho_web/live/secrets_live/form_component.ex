defmodule CymphoWeb.SecretsLive.FormComponent do
  use CymphoWeb, :live_component
  alias Cympho.Secrets
  alias Cympho.Secrets.Secret

  @impl true
  def update(%{secret: secret, form_mode: form_mode, company_id: company_id}, socket) do
    changeset =
      case {form_mode, secret} do
        {:edit, %Secret{} = secret} -> Secret.changeset(secret, %{})
        {:create, nil} -> Secret.changeset(%Secret{}, %{company_id: company_id})
        _ -> Secret.changeset(%Secret{}, %{})
      end

    socket =
      socket
      |> assign(:secret, secret)
      |> assign(:form_mode, form_mode)
      |> assign(:company_id, company_id)
      |> assign(:changeset, changeset)
      |> assign(:trigger_action, false)

    {:ok, socket}
  end

  @impl true
  def handle_event("validate", %{"secret" => secret_params}, socket) do
    changeset =
      %Secret{}
      |> Secret.changeset(secret_params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :changeset, changeset)}
  end

  def handle_event("save", %{"secret" => secret_params}, socket) do
    company_id = socket.assigns.company_id
    secret_params = Map.put(secret_params, "company_id", company_id)

    result =
      case socket.assigns.form_mode do
        :create ->
          Secrets.create_secret(secret_params)

        :edit ->
          Secrets.update_secret(socket.assigns.secret, secret_params)

        :rotate ->
          # For rotation, we need the new value
          case secret_params["value"] || secret_params[:value] do
            nil ->
              {:error, Secret.changeset(socket.assigns.secret, %{}) |> Ecto.Changeset.add_error(:value, "can't be blank")}

            new_value ->
              Secrets.rotate_secret(socket.assigns.secret, new_value)
          end
      end

    case result do
      {:ok, secret} ->
        {:reply, {:ok, secret}, assign(socket, :trigger_action, true)}

      {:error, changeset} ->
        {:noreply, assign(socket, :changeset, changeset)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mb-6 p-4 bg-white/[0.02] border border-border rounded-md">
      <.form
        for={@changeset}
        phx-target={@myself}
        phx-change="validate"
        phx-submit="save"
        id="secret-form"
      >
        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <div class="space-y-2">
            <.label field={:key}>Key</.label>
            <.input
              field={:key}
              type="text"
              placeholder="API_KEY, DATABASE_URL, etc."
              disabled={@form_mode == :edit}
              required
            />
            <.error field={:key} />
          </div>

          <div class="space-y-2">
            <.label field={:scope}>Scope</.label>
            <.input
              field={:scope}
              type="select"
              options={[{"Company": "company"}, {"Instance": "instance"}, {"Agent": "agent"}, {"Project": "project"}]}
              required
            />
            <.error field={:scope} />
          </div>

          <div :if={@changeset.data.scope in ["agent", "project"]} class="space-y-2">
            <.label field={:scope_id}>Scope ID</.label>
            <.input
              field={:scope_id}
              type="text"
              placeholder="Agent or Project ID"
            />
            <.error field={:scope_id} />
          </div>

          <div class="space-y-2">
            <.label field={:value}>
              {if @form_mode == :rotate, do: "New Value", else: "Value"}
            </.label>
            <.input
              field={:value}
              type="password"
              placeholder="Secret value"
              required={@form_mode in [:create, :rotate]}
            />
            <.error field={:value} />
            <p class="text-xs text-text-quaternary">
              {if @form_mode == :rotate, do: "Enter the new secret value to create version #{(@secret.version || 0) + 1}", else: "The value will be encrypted and stored securely"}
            </p>
          </div>

          <div class="space-y-2 md:col-span-2">
            <.label field={:description}>Description</.label>
            <.input
              field={:description}
              type="text"
              placeholder="Optional description of what this secret is for"
            />
            <.error field={:description} />
          </div>
        </div>

        <div class="flex items-center justify-end gap-3 mt-4">
          <button
            type="button"
            phx-click={@on_cancel}
            class="px-4 py-2 bg-white/[0.05] hover:bg-white/[0.1] text-text-secondary rounded-md text-sm font-medium transition-colors"
          >
            Cancel
          </button>
          <button
            type="submit"
            class="px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded-md text-sm font-medium transition-colors"
          >
            {if @form_mode == :create, do: "Create Secret", else: "Save Secret"}
          </button>
        </div>
      </.form>
    </div>
    """
  end
end
