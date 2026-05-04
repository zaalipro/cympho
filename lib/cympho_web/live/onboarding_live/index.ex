defmodule CymphoWeb.OnboardingLive.Index do
  use CymphoWeb, :live_view
  alias Cympho.Companies

  @templates [
    %{
      id: "saas-startup",
      name: "SaaS Startup",
      description: "B2B SaaS company with CEO, CTO, engineers, and marketing team.",
      icon: "🚀",
      color: "#5e6ad2"
    },
    %{
      id: "devtools-company",
      name: "DevTools Company",
      description: "Developer tools company with CLI tools, libraries, and DevRel.",
      icon: "🔧",
      color: "#8b5cf6"
    },
    %{
      id: "content-platform",
      name: "Content Platform",
      description: "AI-augmented media company with editorial and distribution teams.",
      icon: "📝",
      color: "#ec4899"
    },
    %{
      id: "ai-research-lab",
      name: "AI Research Lab",
      description: "ML research organization with scientists and MLOps engineers.",
      icon: "🧪",
      color: "#06b6d4"
    },
    %{
      id: "ecommerce-store",
      name: "E-commerce Store",
      description: "Vertically-integrated e-commerce with product, ops, and marketing.",
      icon: "🛒",
      color: "#10b981"
    }
  ]

  @steps [
    %{
      id: :welcome,
      title: "Start an autonomous company",
      description: "Create a CEO, CTO, engineers, goal, project, and first issue"
    },
    %{
      id: :templates,
      title: "Choose a template",
      description: "Start from scratch or pick a pre-built company template"
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
      |> assign(:bootstrap_result, nil)
      |> assign(:selected_template, nil)
      |> assign(:templates, @templates)
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
      |> Map.merge(
        if(socket.assigns.selected_template,
          do: %{"template_id" => socket.assigns.selected_template.id},
          else: %{}
        )
      )

    case Companies.create_autonomous_company(attrs) do
      {:ok, result} ->
        {:noreply,
         socket
         |> assign(:bootstrap_result, result)
         |> assign(:current_step, 4)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not create company: #{inspect(reason)}")}
    end
  end

  def handle_event("select_template", %{"template_id" => template_id}, socket) do
    template = Enum.find(socket.assigns.templates, fn t -> t.id == template_id end)

    if template do
      form =
        case template_id do
          "saas-startup" -> %{
            "name" => "SaaS Startup Co",
            "goal_title" => "Build and grow a profitable B2B SaaS product",
            "issue_prefix" => "SAS",
            "engineer_count" => "2"
          }
          "devtools-company" -> %{
            "name" => "DevTools Inc",
            "goal_title" => "Build developer tools that scale",
            "issue_prefix" => "DT",
            "engineer_count" => "2"
          }
          "content-platform" -> %{
            "name" => "ContentOps Media",
            "goal_title" => "Build a scalable content operation",
            "issue_prefix" => "CP",
            "engineer_count" => "2"
          }
          "ai-research-lab" -> %{
            "name" => "AI Research Lab",
            "goal_title" => "Advance the state of AI research",
            "issue_prefix" => "RL",
            "engineer_count" => "3"
          }
          "ecommerce-store" -> %{
            "name" => "CommerceOps",
            "goal_title" => "Build a profitable e-commerce brand",
            "issue_prefix" => "EC",
            "engineer_count" => "1"
          }
          _ ->
            socket.assigns.company_form
        end

      {:noreply,
       socket
       |> assign(:selected_template, template)
       |> assign(:company_form, form)
       |> assign(:current_step, 2)}
    else
      {:noreply, socket}
    end
  end

  defp parse_engineer_count(value) when is_integer(value), do: max(0, min(value, 8))

  defp parse_engineer_count(value) when is_binary(value) do
    case Integer.parse(value) do
      {count, _} -> max(0, min(count, 8))
      :error -> 2
    end
  end
end
