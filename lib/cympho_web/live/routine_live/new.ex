defmodule CymphoWeb.RoutineLive.New do
  use CymphoWeb, :live_view
  alias Cympho.Routines
  alias Cympho.Routines.Routine
  alias CymphoWeb.RoutineLive.FormHelpers

  @impl true
  def mount(_params, _session, socket) do
    if is_binary(current_company_id(socket)) do
      changeset = Routines.change_routine(%Routine{})

      socket =
        socket
        |> assign(changeset: changeset, form: to_form(changeset), page_title: "New Routine")
        |> FormHelpers.assign_context_options()

      {:ok, socket}
    else
      {:ok, redirect(socket, to: ~p"/onboarding")}
    end
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("save", %{"routine" => routine_params}, socket) do
    with {:ok, routine_params} <-
           FormHelpers.scoped_routine_params(socket, routine_params, put_company_scope: true) do
      case Routines.create_routine(routine_params) do
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

  defp current_company_id(%{assigns: %{current_company: %{id: id}}}), do: id
  defp current_company_id(_socket), do: nil
end
