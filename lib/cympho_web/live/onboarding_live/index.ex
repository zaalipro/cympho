defmodule CymphoWeb.OnboardingLive.Index do
  use CymphoWeb, :live_view

  alias Cympho.Agents.Agent
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
    blueprints = Companies.autonomous_company_blueprints()

    socket =
      socket
      |> assign(:page_title, "Get Started")
      |> assign(:steps, @steps)
      |> assign(:blueprints, blueprints)
      |> assign(:blueprint_query, "")
      |> assign(:filtered_blueprints, blueprints)
      |> assign(:current_step, 0)
      |> assign(:bootstrap_result, nil)
      |> assign(:company_form, %{
        "blueprint" => "software",
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
    params = maybe_apply_blueprint_defaults(params, socket.assigns.company_form)
    {:noreply, assign(socket, :company_form, params)}
  end

  def handle_event("filter_blueprints", %{"blueprint_query" => query}, socket) do
    query = String.trim(query || "")

    {:noreply,
     socket
     |> assign(:blueprint_query, query)
     |> assign(:filtered_blueprints, filter_blueprints(socket.assigns.blueprints, query))}
  end

  def handle_event("start_autonomous_company", %{"company" => params}, socket) do
    attrs =
      socket.assigns.company_form
      |> Map.merge(params)
      |> Map.update("engineer_count", 2, &parse_engineer_count/1)

    case Companies.create_autonomous_company(attrs) do
      {:ok, result} ->
        {:noreply,
         socket
         |> assign(:bootstrap_result, result)
         |> assign(:current_step, 3)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not create company: #{inspect(reason)}")}
    end
  end

  defp parse_engineer_count(value) when is_integer(value), do: max(0, min(value, 8))

  defp parse_engineer_count(value) when is_binary(value) do
    case Integer.parse(value) do
      {count, _} -> max(0, min(count, 8))
      :error -> 2
    end
  end

  defp maybe_apply_blueprint_defaults(params, current_form) do
    selected = params["blueprint"] || current_form["blueprint"] || "software"
    previous = current_form["blueprint"] || "software"

    if selected != previous do
      case Companies.autonomous_company_blueprint(selected) do
        {:ok, blueprint} ->
          params
          |> Map.put("blueprint", selected)
          |> Map.put("goal_title", blueprint.default_goal)
          |> Map.put("issue_prefix", blueprint.default_prefix)

        {:error, :not_found} ->
          params
      end
    else
      Map.put_new(params, "blueprint", selected)
    end
  end

  defp filter_blueprints(blueprints, ""), do: blueprints

  defp filter_blueprints(blueprints, query) do
    normalized_query = String.downcase(query)

    Enum.filter(blueprints, fn blueprint ->
      [
        blueprint.key,
        blueprint.name,
        blueprint.description,
        blueprint.default_goal,
        blueprint.role_summary
      ]
      |> Enum.join(" ")
      |> String.downcase()
      |> String.contains?(normalized_query)
    end)
  end

  defp role_label(role), do: Agent.role_label(role)
end
