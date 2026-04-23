defmodule CymphoWeb.LabelLive.Index do
  use CymphoWeb, :live_view
  alias Cympho.Labels
  alias Cympho.Labels.Label

  @impl true
  def mount(_params, _session, socket) do
    changeset = Labels.change_label(%Label{})

    {:ok,
     socket
     |> assign(:labels, Labels.list_labels())
     |> assign(:label_changeset, changeset)
     |> assign(:form, to_form(changeset))
     |> assign(:editing_label, nil)}
  end

  @impl true
  def handle_params(params, _url, socket),
    do: {:noreply, apply_action(socket, socket.assigns.live_action, params)}

  defp apply_action(socket, nil, _params), do: apply_action(socket, :index, %{})

  defp apply_action(socket, :index, _params), do: assign(socket, :page_title, "Labels")

  @impl true
  def handle_event("create_label", %{"label" => label_params}, socket) do
    case Labels.create_label(label_params) do
      {:ok, _} ->
        changeset = Labels.change_label(%Label{})

        {:noreply,
         socket
         |> assign(:labels, Labels.list_labels())
         |> assign(:label_changeset, changeset)
         |> assign(:form, to_form(changeset))
         |> put_flash(:info, "Label created")}

      {:error, cs} ->
        {:noreply, assign(socket, :label_changeset, cs) |> assign(:form, to_form(cs))}
    end
  end

  def handle_event("edit_label", %{"id" => id}, socket) do
    label = Labels.get_label!(id)
    changeset = Labels.change_label(label)

    {:noreply,
     socket
     |> assign(:editing_label, label)
     |> assign(:label_changeset, changeset)
     |> assign(:form, to_form(changeset))}
  end

  def handle_event("update_label", %{"label" => params}, socket) do
    case Labels.update_label(socket.assigns.editing_label, params) do
      {:ok, _} ->
        changeset = Labels.change_label(%Label{})

        {:noreply,
         socket
         |> assign(:labels, Labels.list_labels())
         |> assign(:editing_label, nil)
         |> assign(:label_changeset, changeset)
         |> assign(:form, to_form(changeset))
         |> put_flash(:info, "Label updated")}

      {:error, cs} ->
        {:noreply, assign(socket, :label_changeset, cs) |> assign(:form, to_form(cs))}
    end
  end

  def handle_event("cancel_edit", _, socket) do
    changeset = Labels.change_label(%Label{})

    {:noreply,
     socket
     |> assign(:editing_label, nil)
     |> assign(:label_changeset, changeset)
     |> assign(:form, to_form(changeset))}
  end

  def handle_event("delete_label", %{"id" => id}, socket) do
    label = Labels.get_label!(id)
    {:ok, _} = Labels.delete_label(label)

    {:noreply,
     socket |> assign(:labels, Labels.list_labels()) |> put_flash(:info, "Label deleted")}
  end

  defp text_color("#" <> hex) do
    {:ok, <<r, g, b>>} = Base.decode16(String.upcase(hex))
    if (0.299 * r + 0.587 * g + 0.114 * b) / 255 > 0.5, do: "#000000", else: "#FFFFFF"
  end

  defp text_color(_), do: "#FFFFFF"
end
