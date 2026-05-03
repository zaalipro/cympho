defmodule CymphoWeb.OnboardingLive.Index do
  use CymphoWeb, :live_view
  alias Cympho.Companies

  @steps [
    %{
      id: :welcome,
      title: "Start an autonomous company",
      description: "Create a CEO, CTO, engineers, goal, project, and first issue"
    },
    %{
      id: :workspace,
      title: "Company operating system",
      description: "Set the company goal and default execution team"
    },
    %{
      id: :shortcuts,
      title: "Quick navigation",
      description: "Learn keyboard shortcuts to move fast"
    },
    %{
      id: :ready,
      title: "You're all set!",
      description: "Start managing your projects with AI agents"
    }
  ]

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Get Started")
      |> assign(:steps, @steps)
      |> assign(:current_step, 0)
      |> assign(:company_form, %{
        "name" => "Autonomous Software Company",
        "goal_title" => "Build and run the business autonomously",
        "issue_prefix" => "LLM",
        "engineer_count" => "2"
      })

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

  def handle_event("update_company_form", %{"company" => params}, socket) do
    {:noreply, assign(socket, :company_form, params)}
  end

  def handle_event("start_autonomous_company", %{"company" => params}, socket) do
    attrs =
      params
      |> Map.update("engineer_count", 2, &parse_engineer_count/1)

    case Companies.create_autonomous_company(attrs) do
      {:ok, _result} ->
        {:noreply,
         socket
         |> put_flash(:info, "Autonomous company created.")
         |> push_navigate(to: ~p"/kanban")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not create company: #{inspect(reason)}")}
    end
  end

  defp parse_engineer_count(value) when is_integer(value), do: max(1, min(value, 8))

  defp parse_engineer_count(value) when is_binary(value) do
    case Integer.parse(value) do
      {count, _} -> max(1, min(count, 8))
      :error -> 2
    end
  end
end
