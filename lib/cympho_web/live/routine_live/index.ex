defmodule CymphoWeb.RoutineLive.Index do
  use CymphoWeb, :live_view
  alias Cympho.Routines
  alias Cympho.Routines.Routine

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:infinite_scroll, %{})
      |> assign(:routine_health, load_routine_health(socket))

    {:ok, init_stream(socket, :routine, &fetch_routines(socket, &1))}
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
  def handle_event("next-page", _params, socket) do
    {:reply, %{}, load_next(socket, :routine, &fetch_routines(socket, &1))}
  end

  @impl true
  def handle_event("delete_routine", %{"id" => id}, socket) do
    routine = Routines.get_routine!(id)
    {:ok, _} = Routines.archive_routine(routine)
    {:noreply, refresh_routines(socket)}
  end

  @impl true
  def handle_event("pause_routine", %{"id" => id}, socket) do
    routine = Routines.get_routine!(id)

    case Routines.pause_routine(routine) do
      {:ok, _} ->
        {:noreply, refresh_routines(socket)}

      {:error, :invalid_transition} ->
        {:noreply, put_flash(socket, :error, "Cannot pause a routine in #{routine.status} state")}
    end
  end

  @impl true
  def handle_event("resume_routine", %{"id" => id}, socket) do
    routine = Routines.get_routine!(id)

    case Routines.resume_routine(routine) do
      {:ok, _} ->
        {:noreply, refresh_routines(socket)}

      {:error, :invalid_transition} ->
        {:noreply,
         put_flash(socket, :error, "Cannot resume a routine in #{routine.status} state")}
    end
  end

  defp fetch_routines(_socket, cursor) do
    Routines.list_routines_page(after: cursor)
  end

  defp refresh_routines(socket) do
    socket
    |> assign(:routine_health, load_routine_health(socket))
    |> reset_stream(:routine, &fetch_routines(socket, &1))
  end

  defp load_routine_health(_socket), do: Routines.health_summary()

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

  def routine_priority_class(:critical), do: "border-brand/25 bg-brand/10 text-brand"
  def routine_priority_class(:high), do: "border-amber-500/25 bg-amber-500/10 text-amber-400"
  def routine_priority_class(:medium), do: "border-brand/25 bg-brand/10 text-brand"

  def routine_priority_class(:low),
    do: "border-text-quaternary/20 bg-text-quaternary/10 text-text-tertiary"

  def routine_priority_class(_), do: "border-border bg-surface text-text-tertiary"

  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :tone, :atom, default: :neutral

  def routine_health_metric(assigns) do
    ~H"""
    <div class="bg-surface/70 px-3 py-2 text-center">
      <p class={"font-mono text-[18px] font-590 leading-none #{routine_metric_text(@tone)}"}>
        {@value}
      </p>
      <p class="mt-1 text-[10px] uppercase tracking-[0.12em] text-text-quaternary">
        {@label}
      </p>
    </div>
    """
  end

  def routine_health_badge(:critical), do: "border-red-500/25 bg-red-500/10 text-red-300"
  def routine_health_badge(:warning), do: "border-amber-500/25 bg-amber-500/10 text-amber-300"

  def routine_health_badge(:healthy),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"

  def routine_health_badge(:empty), do: "border-border bg-surface text-text-tertiary"
  def routine_health_badge(_), do: "border-border bg-surface text-text-tertiary"

  def routine_metric_text(:critical), do: "text-red-300"
  def routine_metric_text(:warning), do: "text-amber-300"
  def routine_metric_text(:ok), do: "text-emerald-300"
  def routine_metric_text(_), do: "text-text-primary"

  def routine_recommendation_class(:critical), do: "border-red-500/20 bg-red-500/10 text-red-100"

  def routine_recommendation_class(:warning),
    do: "border-amber-500/20 bg-amber-500/10 text-amber-100"

  def routine_recommendation_class(_), do: "border-border bg-surface text-text-secondary"
end
