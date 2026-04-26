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

    form = to_form(changeset, as: :secret)

    socket =
      socket
      |> assign(:secret, secret)
      |> assign(:form_mode, form_mode)
      |> assign(:company_id, company_id)
      |> assign(:form, form)

    {:ok, socket}
  end

  @impl true
  def handle_event("validate", %{"secret" => secret_params}, socket) do
    form =
      %Secret{}
      |> Secret.changeset(secret_params)
      |> Map.put(:action, :validate)
      |> to_form(as: :secret)

    {:noreply, assign(socket, :form, form)}
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
          case secret_params["value"] || secret_params[:value] do
            nil ->
              {:error,
               Secret.changeset(socket.assigns.secret, %{})
               |> Ecto.Changeset.add_error(:value, "can't be blank")}

            new_value ->
              Secrets.rotate_secret(socket.assigns.secret, new_value)
          end
      end

    case result do
      {:ok, secret} ->
        {:reply, {:ok, secret}, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :secret))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mb-6 p-4 bg-subtle border border-border rounded-lg">
      <.form for={@form} phx-target={@myself} phx-change="validate" phx-submit="save" id="secret-form">
        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <.input
            field={@form[:key]}
            label="Key"
            placeholder="API_KEY, DATABASE_URL, etc."
            disabled={@form_mode == :edit}
            required
          />

          <.select
            name={@form[:scope].name}
            label="Scope"
            options={[
              {"Company", "company"},
              {"Instance", "instance"},
              {"Agent", "agent"},
              {"Project", "project"}
            ]}
            value={@form[:scope].value}
            required
          />

          <div :if={@form[:scope].value in ["agent", "project"]}>
            <.input
              field={@form[:scope_id]}
              label="Scope ID"
              placeholder="Agent or Project ID"
            />
          </div>

          <.input
            field={@form[:value]}
            label={if @form_mode == :rotate, do: "New Value", else: "Value"}
            type="password"
            placeholder="Secret value"
            required={@form_mode in [:create, :rotate]}
          />

          <div class="md:col-span-2">
            <.input
              field={@form[:description]}
              label="Description"
              placeholder="Optional description of what this secret is for"
            />
          </div>
        </div>

        <div class="flex items-center justify-end gap-3 mt-4">
          <button
            type="button"
            phx-click={@on_cancel}
            class="px-4 py-2 bg-surface hover:bg-surface-hover text-text-secondary rounded-lg text-sm font-medium transition-colors"
          >
            Cancel
          </button>
          <button
            type="submit"
            class="px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded-lg text-sm font-medium transition-colors"
          >
            {if @form_mode == :create, do: "Create Secret", else: "Save Secret"}
          </button>
        </div>
      </.form>
    </div>
    """
  end
end
