defmodule CymphoWeb.OnboardingLive.Index do
  use CymphoWeb, :live_view

  @steps [
    %{id: :welcome, title: "Welcome to Cympho", description: "Your AI-powered project management workspace"},
    %{id: :workspace, title: "Create your workspace", description: "Set up projects and invite your team"},
    %{id: :shortcuts, title: "Quick navigation", description: "Learn keyboard shortcuts to move fast"},
    %{id: :ready, title: "You're all set!", description: "Start managing your projects with AI agents"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Get Started")
      |> assign(:steps, @steps)
      |> assign(:current_step, 0)

    {:ok, socket}
  end

  @impl true
  def handle_event("next_step", _params, socket) do
    current = socket.assigns.current_step
    max = length(socket.assigns.steps) - 1

    if current < max do
      {:noreply, assign(socket, :current_step, current + 1)}
    else
      {:noreply, push_navigate(socket, to: ~p"/issues")}
    end
  end

  def handle_event("prev_step", _params, socket) do
    current = socket.assigns.current_step
    if current > 0 do
      {:noreply, assign(socket, :current_step, current - 1)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("skip", _params, socket) do
    {:noreply, push_navigate(socket, to: ~p"/issues")}
  end
end
