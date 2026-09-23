defmodule CymphoWeb.RoutineLive.Edit do
  use CymphoWeb, :live_view
  alias Cympho.Routines
  alias CymphoWeb.RoutineLive.FormHelpers

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case get_scoped_routine(socket, id) do
      {:ok, routine} ->
        changeset = Routines.change_routine(routine)

        socket =
          socket
          |> assign(
            routine: routine,
            changeset: changeset,
            form: to_form(changeset),
            page_title: "Edit Routine"
          )
          |> FormHelpers.assign_context_options()

        {:ok, socket}

      {:error, :not_found} ->
        {:ok, push_navigate(socket, to: ~p"/routines")}
    end
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("save", %{"routine" => routine_params}, socket) do
    with {:ok, routine_params} <-
           FormHelpers.scoped_routine_params(socket, routine_params, put_company_scope: false) do
      case Routines.update_routine(socket.assigns.routine, routine_params) do
        {:ok, routine} ->
          {:noreply, push_navigate(socket, to: ~p"/routines/#{routine.id}")}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply, assign(socket, changeset: changeset, form: to_form(changeset))}
      end
    else
      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Choose an owner and project from this company.")}
    end
  end

  defp get_scoped_routine(socket, id) do
    case current_company_id(socket) do
      nil -> {:error, :not_found}
      company_id -> Routines.get_company_routine(company_id, id)
    end
  end

  defp current_company_id(%{assigns: %{current_company: %{id: id}}}), do: id
  defp current_company_id(_socket), do: nil
end
