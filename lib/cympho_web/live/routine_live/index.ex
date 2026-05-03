defmodule CymphoWeb.RoutineLive.Index do
  use CymphoWeb, :live_view
  alias Cympho.Routines
  alias Cympho.Routines.Routine

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :routines, Routines.list_routines())}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, nil, _params), do: apply_action(socket, :index, %{})

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Routines")
    |> assign(:routine, nil)
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New Routine")
    |> assign(:routine, %Routine{})
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    socket
    |> assign(:page_title, "Edit Routine")
    |> assign(:routine, Routines.get_routine!(id))
  end

  @impl true
  def handle_event("delete_routine", %{"id" => id}, socket) do
    routine = Routines.get_routine!(id)
    {:ok, _} = Routines.archive_routine(routine)
    {:noreply, assign(socket, :routines, Routines.list_routines())}
  end

  @impl true
  def handle_event("pause_routine", %{"id" => id}, socket) do
    routine = Routines.get_routine!(id)

    case Routines.pause_routine(routine) do
      {:ok, _} ->
        {:noreply, assign(socket, :routines, Routines.list_routines())}

      {:error, :invalid_transition} ->
        {:noreply, put_flash(socket, :error, "Cannot pause a routine in #{routine.status} state")}
    end
  end

  @impl true
  def handle_event("resume_routine", %{"id" => id}, socket) do
    routine = Routines.get_routine!(id)

    case Routines.resume_routine(routine) do
      {:ok, _} ->
        {:noreply, assign(socket, :routines, Routines.list_routines())}

      {:error, :invalid_transition} ->
        {:noreply,
         put_flash(socket, :error, "Cannot resume a routine in #{routine.status} state")}
    end
  end

  def routine_label(nil), do: "Unknown"

  def routine_label(value) do
    value
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  def routine_status_class(:active), do: "border-success/20 bg-success/10 text-success"
  def routine_status_class(:paused), do: "border-amber-500/20 bg-amber-500/10 text-amber-400"

  def routine_status_class(:archived),
    do: "border-text-quaternary/20 bg-text-quaternary/10 text-text-tertiary"

  def routine_status_class(_), do: "border-border bg-surface text-text-tertiary"

  def routine_priority_class(:critical), do: "border-red-500/25 bg-red-500/10 text-red-400"
  def routine_priority_class(:high), do: "border-amber-500/25 bg-amber-500/10 text-amber-400"
  def routine_priority_class(:medium), do: "border-brand/25 bg-brand/10 text-brand"

  def routine_priority_class(:low),
    do: "border-text-quaternary/20 bg-text-quaternary/10 text-text-tertiary"

  def routine_priority_class(_), do: "border-border bg-surface text-text-tertiary"
end
