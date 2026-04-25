defmodule CymphoWeb.LabelLive.FormComponent do
  use CymphoWeb, :live_component
  alias Cympho.Labels

  @impl true
  def render(assigns) do
    ~H"""
    <div class="label-form">
      <.simple_form
        for={@form}
        as={:label}
        phx-submit="save"
        phx-target={@myself}
      >
        <.input field={@form[:name]} label="Name" />
        <.input field={@form[:color]} label="Color" placeholder="#FF0000" />
        <.input field={@form[:project_id]} label="Project ID" />

        <:actions>
          <.button type="submit">{if @label.id, do: "Update Label", else: "Create Label"}</.button>
        </:actions>
      </.simple_form>
    </div>
    """
  end

  @impl true
  def update(assigns, socket) do
    changeset = Labels.change_label(assigns.label)

    {:ok,
     assign(socket,
       label: assigns.label,
       action: assigns.action,
       changeset: changeset,
       form: to_form(changeset)
     )}
  end

  @impl true
  def handle_event("save", %{"label" => label_params}, socket) do
    save_label(socket, socket.assigns.action, label_params)
  end

  defp save_label(socket, :edit, label_params) do
    case Labels.update_label(socket.assigns.label, label_params) do
      {:ok, label} ->
        send(self(), {:label_updated, label})
        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, changeset: changeset, form: to_form(changeset))}
    end
  end

  defp save_label(socket, :new, label_params) do
    case Labels.create_label(label_params) do
      {:ok, label} ->
        send(self(), {:label_created, label})
        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, changeset: changeset, form: to_form(changeset))}
    end
  end
end
