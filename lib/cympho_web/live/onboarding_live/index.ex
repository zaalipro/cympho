defmodule CymphoWeb.OnboardingLive.Index do
  use CymphoWeb, :live_view

  alias Cympho.Agents.Agent
  alias Cympho.Companies

  @steps [
    %{
      id: :blueprint,
      title: "Choose a blueprint",
      description: "Pick the kind of company your agents will run"
    },
    %{
      id: :company,
      title: "Name the company",
      description: "Set the company name, goal, and issue prefix"
    },
    %{
      id: :team,
      title: "Build the team",
      description: "Pick your engineers and which AI each role uses"
    },
    %{
      id: :launch,
      title: "Review and launch",
      description: "Confirm the plan, then launch"
    },
    %{
      id: :ready,
      title: "You're all set",
      description: "Your autonomous company is live"
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
      |> assign(:step_error, nil)
      |> assign(:bootstrap_result, nil)
      |> assign(:company_form, %{
        "blueprint" => "software",
        "name" => "Autonomous Software Company",
        "goal_title" => "Build and run the business autonomously",
        "project_name" => "Company OS",
        "issue_prefix" => "LLM",
        "engineer_count" => "2",
        "engineer_names" => [],
        "adapter" => "claude_code",
        "runtime_command" => "",
        "runtime_model" => "",
        "role_overrides" => false,
        "role_runtimes" => %{
          "ceo" => %{"adapter" => "", "model" => "", "command" => ""},
          "cto" => %{"adapter" => "", "model" => "", "command" => ""},
          "engineer" => %{"adapter" => "", "model" => "", "command" => ""}
        }
      })

    {:ok, socket}
  end

  @impl true
  def handle_event("next_step", _params, socket) do
    step = Enum.at(socket.assigns.steps, socket.assigns.current_step)

    case validate_step(step.id, socket.assigns.company_form) do
      :ok ->
        max = length(socket.assigns.steps) - 1
        next = min(socket.assigns.current_step + 1, max)
        {:noreply, socket |> assign(:current_step, next) |> assign(:step_error, nil)}

      {:error, message} ->
        {:noreply, assign(socket, :step_error, message)}
    end
  end

  def handle_event("prev_step", _params, socket) do
    {:noreply,
     socket
     |> assign(:current_step, max(socket.assigns.current_step - 1, 0))
     |> assign(:step_error, nil)}
  end

  def handle_event("skip", _params, socket) do
    if socket.assigns[:current_company] do
      {:noreply, push_navigate(socket, to: ~p"/issues")}
    else
      {:noreply, assign(socket, :step_error, "Finish setup to enter Cympho.")}
    end
  end

  def handle_event("update_company_form", %{"company" => params}, socket) do
    params = maybe_apply_blueprint_defaults(params, socket.assigns.company_form)
    form = deep_merge_form(socket.assigns.company_form, params)
    {:noreply, socket |> assign(:company_form, form) |> assign(:step_error, nil)}
  end

  def handle_event("toggle_role_overrides", _params, socket) do
    form =
      Map.update(socket.assigns.company_form, "role_overrides", true, &(!&1))

    {:noreply, assign(socket, :company_form, form)}
  end

  def handle_event("filter_blueprints", %{"blueprint_query" => query}, socket) do
    query = String.trim(query || "")

    {:noreply,
     socket
     |> assign(:blueprint_query, query)
     |> assign(:filtered_blueprints, filter_blueprints(socket.assigns.blueprints, query))}
  end

  # Ignores repeat clicks after a successful launch (the ready step already
  # shows the result); a second transaction would create a duplicate company.
  def handle_event("start_autonomous_company", _params, socket) do
    if socket.assigns.bootstrap_result do
      {:noreply, socket}
    else
      launch_company(socket)
    end
  end

  @allowed_adapters ~w(claude_code codex cursor http)

  defp launch_company(socket) do
    form = socket.assigns.company_form

    attrs = %{
      "blueprint" => form["blueprint"],
      "name" => form["name"],
      "goal_title" => form["goal_title"],
      "project_name" => form["project_name"],
      "issue_prefix" => form["issue_prefix"],
      "engineer_count" => engineer_count(form),
      "engineer_names" => form["engineer_names"] || [],
      "adapter" => sanitize_adapter(form["adapter"]),
      "agent_runtime" => %{
        "command" => form["runtime_command"],
        "model" => form["runtime_model"]
      },
      "role_runtimes" => role_runtimes_attrs(form),
      "owner_user_id" => socket.assigns.current_user.id
    }

    with :ok <- validate_step(:company, form),
         :ok <- validate_runtime_compat(attrs) do
      case create_company_safely(attrs) do
        {:ok, result} ->
          {:noreply,
           socket
           |> assign(:bootstrap_result, result)
           |> assign(:step_error, nil)
           |> assign(:current_step, 4)}

        {:error, reason} ->
          {:noreply, assign(socket, :step_error, "Could not create company: #{inspect(reason)}")}
      end
    else
      # Send the owner back to the team step (where AI runtimes are picked) so
      # they can fix a model/runtime mismatch instead of launching into a
      # company whose agents can never dispatch.
      {:error, :runtime_incompatible, message} ->
        {:noreply, socket |> assign(:current_step, 2) |> assign(:step_error, message)}

      {:error, message} ->
        {:noreply, socket |> assign(:current_step, 1) |> assign(:step_error, message)}
    end
  end

  # Reject an adapter/model combination that could never dispatch — e.g. an
  # OpenAI model under Claude Code's default `claude` command. Preflight already
  # catches this, but only after the issue is created and silently stuck, so we
  # surface it here at setup time. Checks the shared runtime and every per-role
  # override.
  defp validate_runtime_compat(attrs) do
    shared_adapter = attrs["adapter"]

    runtimes =
      [
        {shared_adapter, get_in(attrs, ["agent_runtime", "model"]),
         get_in(attrs, ["agent_runtime", "command"])}
      ] ++
        Enum.map(attrs["role_runtimes"] || %{}, fn {_role, rt} ->
          {rt["adapter"] || shared_adapter, rt["model"], rt["command"]}
        end)

    Enum.reduce_while(runtimes, :ok, fn {adapter, model, command}, _acc ->
      config = %{"model" => model || "", "command" => command || ""}

      case Cympho.Adapters.ModelCompatibility.validate(adapter, config) do
        :ok -> {:cont, :ok}
        {:error, message} -> {:halt, {:error, :runtime_incompatible, message}}
      end
    end)
  end

  # The engine uses Repo.insert! throughout, so changeset-invalid input raises
  # out of the transaction instead of returning {:error, _}. Convert raises
  # into the error banner rather than crashing the LiveView and losing all
  # wizard state. Nothing persists either way — the transaction rolls back.
  defp create_company_safely(attrs) do
    Companies.create_autonomous_company(attrs)
  rescue
    error in [Ecto.InvalidChangesetError] -> {:error, error.changeset.errors}
    error -> {:error, error}
  end

  # The <select> constrains the browser, not the client: a tampered payload
  # could smuggle any existing atom into the agent adapter enum.
  defp sanitize_adapter(adapter) when adapter in @allowed_adapters, do: adapter
  defp sanitize_adapter(_), do: "claude_code"

  # Nested maps (role_runtimes) merge per key so editing one role's model
  # doesn't drop the other roles' values from the change payload.
  defp deep_merge_form(form, params) do
    Map.merge(form, params, fn
      _key, %{} = old, %{} = new -> Map.merge(old, new, &deep_merge_value/3)
      _key, _old, new -> new
    end)
  end

  defp deep_merge_value(_key, %{} = old, %{} = new), do: Map.merge(old, new)
  defp deep_merge_value(_key, _old, new), do: new

  # Only pass per-role runtimes to the launch engine when the user opened the
  # override panel; otherwise every role uses the shared runtime.
  defp role_runtimes_attrs(%{"role_overrides" => true} = form) do
    Map.new(form["role_runtimes"] || %{}, fn {role, runtime} ->
      {role,
       %{
         "adapter" => sanitize_role_adapter(runtime["adapter"], form["adapter"]),
         "model" => runtime["model"],
         "command" => runtime["command"]
       }}
    end)
  end

  defp role_runtimes_attrs(_form), do: %{}

  defp sanitize_role_adapter(adapter, _shared) when adapter in @allowed_adapters, do: adapter
  defp sanitize_role_adapter(_, shared), do: sanitize_adapter(shared)

  def engineer_count(form) do
    case Integer.parse(to_string(form["engineer_count"] || "2")) do
      {count, _} -> count |> max(0) |> min(8)
      :error -> 2
    end
  end

  def engineer_name_value(form, index) do
    case Enum.at(form["engineer_names"] || [], index - 1) do
      name when is_binary(name) and name != "" -> name
      _ -> "Engineer #{index}"
    end
  end

  def selected_blueprint(blueprints, form) do
    Enum.find(blueprints, &(&1.key == form["blueprint"])) || List.first(blueprints)
  end

  # The prefix cap is 7 (not the schema's 10) because the launch engine
  # truncates prefixes to 7 characters; the name minimum is 3 because the
  # company slug derived from it must satisfy validate_length(:slug, min: 3).
  defp validate_step(:company, form) do
    cond do
      String.trim(form["name"] || "") == "" ->
        {:error, "Company name is required."}

      String.length(String.trim(form["name"])) < 3 ->
        {:error, "Company name must be at least 3 characters."}

      String.trim(form["goal_title"] || "") == "" ->
        {:error, "Company goal is required."}

      String.trim(form["project_name"] || "") == "" ->
        {:error, "Project name is required."}

      not Regex.match?(~r/^[A-Z]{2,7}$/, form["issue_prefix"] || "") ->
        {:error, "Issue prefix must be 2-7 uppercase letters."}

      true ->
        :ok
    end
  end

  defp validate_step(_step, _form), do: :ok

  defp maybe_apply_blueprint_defaults(params, current_form) do
    selected = params["blueprint"] || current_form["blueprint"] || "software"
    previous = current_form["blueprint"] || "software"

    if selected != previous do
      case Companies.autonomous_company_blueprint(selected) do
        {:ok, blueprint} ->
          params
          |> Map.put("blueprint", selected)
          |> Map.put("goal_title", blueprint.default_goal)
          |> Map.put("project_name", blueprint.project_name)
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
        blueprint.role_summary,
        Enum.join(blueprint.roles, " "),
        Enum.join(blueprint.capability_tags, " "),
        Enum.join(blueprint.seed_issue_titles, " ")
      ]
      |> Enum.join(" ")
      |> String.downcase()
      |> String.contains?(normalized_query)
    end)
  end

  defp role_label(role), do: Agent.role_label(role)

  # ── AI provider helpers (team step) ────────────────────────────────────

  def adapter_options do
    [
      {"Claude Code", "claude_code"},
      {"Codex (OpenAI)", "codex"},
      {"Cursor", "cursor"},
      {"HTTP", "http"}
    ]
  end

  def model_placeholder("codex"), do: "gpt-5.5"
  def model_placeholder("cursor"), do: "auto"
  def model_placeholder(_adapter), do: "provider default"

  def command_placeholder("codex"), do: "codex (default)"
  def command_placeholder("cursor"), do: "agent (default)"
  def command_placeholder(_adapter), do: "claude (default)"

  def model_suggestion_lists do
    [
      {"claude_code", ["claude-opus-4-8", "claude-sonnet-5", "claude-haiku-4-5"]},
      {"codex", Enum.map(Cympho.Adapters.CodexAdapter.model_options(), &elem(&1, 1))},
      {"cursor", Enum.map(Cympho.Adapters.RuntimeOptions.cursor_model_options(), &elem(&1, 1))},
      {"http", []}
    ]
  end

  def role_runtime_value(form, role, key) do
    get_in(form, ["role_runtimes", role, key]) || ""
  end

  # The provider whose model suggestions apply to a role row: its own pick,
  # or the shared provider when the role select is on "Same as above".
  def role_runtime_adapter(form, role) do
    case role_runtime_value(form, role, "adapter") do
      "" -> form["adapter"] || "claude_code"
      adapter -> adapter
    end
  end

  def role_runtime_customized?(form, role) do
    role_runtime_value(form, role, "adapter") != "" or
      role_runtime_value(form, role, "model") != "" or
      role_runtime_value(form, role, "command") != ""
  end

  def runtime_summary(adapter, model) do
    label =
      Enum.find_value(adapter_options(), adapter, fn {label, value} ->
        if value == adapter, do: label
      end)

    if model in [nil, ""], do: "#{label} · default model", else: "#{label} · #{model}"
  end
end
