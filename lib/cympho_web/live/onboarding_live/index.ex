defmodule CymphoWeb.OnboardingLive.Index do
  use CymphoWeb, :live_view

  alias Cympho.Agents.Agent
  alias Cympho.Companies
  alias Cympho.Onboarding

  @steps [
    %{
      id: :blueprint,
      title: "Choose a blueprint",
      description: "Pick the kind of company your agents will run"
    },
    %{
      id: :company,
      title: "Name the company",
      description: "Set the company name, goal, and issue prefix",
      simple_description: "Set the company name, its first goal, and its first project"
    },
    %{
      id: :team,
      title: "Build the team",
      description: "Pick your engineers and which AI each role uses",
      simple_description: "Pick your engineers and the AI they all run on"
    },
    %{
      id: :launch,
      title: "Review and launch",
      description: "Confirm the plan, then launch"
    },
    %{
      id: :ready,
      title: "You're all set",
      description: "Your company structure and starting work are ready"
    }
  ]

  # Simple mode hides the issue prefix and the per-role model fields, so the step
  # subtitle must not promise controls the reader cannot see.
  defp step_simple_description(step), do: Map.get(step, :simple_description, step.description)

  @impl true
  def mount(_params, _session, socket) do
    blueprints = Companies.autonomous_company_blueprints()
    current_company_id = socket.assigns[:current_company] && socket.assigns.current_company.id
    draft = Onboarding.get_draft(socket.assigns.current_user.id, current_company_id)
    onboarding_path = restore_onboarding_path(draft, socket.assigns[:current_company])
    company_form = restore_company_form(draft, onboarding_path)
    current_step = restore_current_step(draft, onboarding_path)
    improvement_submission_id = restore_improvement_submission_id(draft, onboarding_path)

    socket =
      socket
      |> assign(:page_title, "Get Started")
      |> assign(:steps, @steps)
      |> assign(:blueprints, blueprints)
      |> assign(:blueprint_query, "")
      |> assign(:filtered_blueprints, blueprints)
      |> assign(:onboarding_path, onboarding_path)
      |> assign(:current_step, current_step)
      |> assign(:step_error, nil)
      |> assign(:bootstrap_result, nil)
      |> assign(:improvement_submission_id, improvement_submission_id)
      |> assign(:company_form, company_form)

    {:ok, socket}
  end

  @impl true
  def handle_event("next_step", _params, socket) do
    step = Enum.at(socket.assigns.steps, socket.assigns.current_step)

    case validate_step(step.id, socket.assigns.company_form) do
      :ok ->
        max = length(socket.assigns.steps) - 1
        next = min(socket.assigns.current_step + 1, max)

        {:noreply,
         socket
         |> assign(:current_step, next)
         |> assign(:step_error, nil)
         |> persist_draft()}

      {:error, message} ->
        {:noreply, socket |> assign(:step_error, message) |> persist_draft()}
    end
  end

  def handle_event("prev_step", _params, socket) do
    {:noreply,
     socket
     |> assign(:current_step, max(socket.assigns.current_step - 1, 0))
     |> assign(:step_error, nil)
     |> persist_draft()}
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

    {:noreply,
     socket |> assign(:company_form, form) |> assign(:step_error, nil) |> persist_draft()}
  end

  def handle_event("toggle_role_overrides", _params, socket) do
    form =
      Map.update(socket.assigns.company_form, "role_overrides", true, &(!&1))

    {:noreply, socket |> assign(:company_form, form) |> persist_draft()}
  end

  def handle_event("filter_blueprints", %{"blueprint_query" => query}, socket) do
    query = String.trim(query || "")

    {:noreply,
     socket
     |> assign(:blueprint_query, query)
     |> assign(:filtered_blueprints, filter_blueprints(socket.assigns.blueprints, query))}
  end

  def handle_event("select_onboarding_path", %{"path" => "start"}, socket) do
    {:noreply,
     socket
     |> assign(:onboarding_path, :start)
     |> assign(:current_step, 0)
     |> assign(:company_form, default_company_form())
     |> assign(:step_error, nil)
     |> persist_draft()}
  end

  def handle_event("select_onboarding_path", %{"path" => "improve"}, socket) do
    if socket.assigns[:current_company] do
      {:noreply,
       socket
       |> assign(:onboarding_path, :improve)
       |> assign(:current_step, 0)
       |> assign(:improvement_submission_id, Ecto.UUID.generate())
       |> assign(
         :company_form,
         default_company_form()
         |> Map.put("goal_title", "")
         |> Map.put("improvement_details", "")
       )
       |> assign(:step_error, nil)
       |> persist_draft()}
    else
      {:noreply, assign(socket, :step_error, "Create your first company to continue.")}
    end
  end

  def handle_event("select_onboarding_path", _params, socket) do
    {:noreply, assign(socket, :step_error, "Choose how you want to get started.")}
  end

  def handle_event("change_onboarding_path", _params, socket) do
    if socket.assigns[:current_company] do
      _ = Onboarding.clear_draft(socket.assigns.current_user.id)

      {:noreply,
       socket
       |> assign(:onboarding_path, nil)
       |> assign(:current_step, 0)
       |> assign(:improvement_submission_id, nil)
       |> assign(:company_form, default_company_form())
       |> assign(:step_error, nil)}
    else
      {:noreply, socket}
    end
  end

  # Ignores repeat clicks after a successful launch (the ready step already
  # shows the result); a second transaction would create a duplicate company.
  def handle_event("start_autonomous_company", _params, socket) do
    cond do
      socket.assigns.bootstrap_result -> {:noreply, socket}
      socket.assigns.onboarding_path != :start -> {:noreply, socket}
      true -> launch_company(socket)
    end
  end

  def handle_event("create_improvement", _params, socket) do
    cond do
      socket.assigns.bootstrap_result ->
        {:noreply, socket}

      socket.assigns.onboarding_path != :improve or is_nil(socket.assigns[:current_company]) ->
        {:noreply, assign(socket, :step_error, "Choose a company improvement first.")}

      true ->
        create_improvement(socket)
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
          _ = Onboarding.clear_draft(socket.assigns.current_user.id)

          {:noreply,
           socket
           |> assign(:bootstrap_result, result)
           |> assign(:company_form, default_company_form())
           |> assign(:step_error, nil)
           |> assign(:current_step, 4)}

        {:error, _reason} ->
          {:noreply,
           socket
           |> assign(
             :step_error,
             "We couldn't launch the company. Review the company and AI settings, then try again."
           )
           |> persist_draft()}
      end
    else
      # Send the owner back to the team step (where AI runtimes are picked) so
      # they can fix a model/runtime mismatch instead of launching into a
      # company whose agents can never dispatch.
      {:error, :runtime_incompatible, message} ->
        {:noreply,
         socket
         |> assign(:current_step, 2)
         |> assign(:step_error, message)
         |> persist_draft()}

      {:error, message} ->
        {:noreply,
         socket
         |> assign(:current_step, 1)
         |> assign(:step_error, message)
         |> persist_draft()}
    end
  end

  defp create_improvement(socket) do
    company = socket.assigns.current_company
    user = socket.assigns.current_user

    attrs =
      Map.put(
        socket.assigns.company_form,
        "submission_id",
        socket.assigns.improvement_submission_id || Ecto.UUID.generate()
      )

    case Onboarding.create_improvement(company.id, user.id, attrs) do
      {:ok, %{goal: goal, issue: issue}} ->
        result = %{
          mode: :improve,
          company: company,
          goal: goal,
          issue: issue,
          agents: [],
          seed_issues: [issue]
        }

        {:noreply,
         socket
         |> assign(:bootstrap_result, result)
         |> assign(:improvement_submission_id, nil)
         |> assign(:company_form, default_company_form())
         |> assign(:step_error, nil)}

      {:error, :goal_required} ->
        {:noreply,
         socket
         |> assign(:step_error, "Improvement goal is required.")
         |> persist_draft()}

      {:error, :sensitive_content} ->
        {:noreply,
         socket
         |> assign(
           :step_error,
           "Remove credentials or secrets before saving this improvement."
         )
         |> persist_draft()}

      {:error, :forbidden} ->
        {:noreply,
         socket
         |> assign(
           :step_error,
           "Only a company owner, admin, or board member can create company improvements."
         )
         |> persist_draft()}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:step_error, "We couldn't create this improvement. Review it and try again.")
         |> persist_draft()}
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

  defp default_company_form do
    %{
      "blueprint" => "software",
      "name" => "Autonomous Software Company",
      "goal_title" => "Build and run the business autonomously",
      "improvement_details" => "",
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
    }
  end

  defp restore_onboarding_path(_draft, nil), do: :start

  defp restore_onboarding_path(draft, _current_company) do
    case draft["path"] do
      "start" -> :start
      "improve" -> :improve
      _ -> nil
    end
  end

  defp restore_company_form(%{"path" => path, "form" => form}, onboarding_path)
       when is_map(form) and path in ["start", "improve"] do
    if path == to_string(onboarding_path),
      do: deep_merge_form(default_company_form(), form),
      else: default_company_form()
  end

  defp restore_company_form(_draft, _onboarding_path), do: default_company_form()

  defp restore_current_step(draft, :start) do
    case draft["current_step"] do
      step when is_integer(step) -> step |> max(0) |> min(3)
      _ -> 0
    end
  end

  defp restore_current_step(_draft, _path), do: 0

  defp restore_improvement_submission_id(draft, :improve) do
    draft["submission_id"] || Ecto.UUID.generate()
  end

  defp restore_improvement_submission_id(_draft, _path), do: nil

  defp persist_draft(socket) do
    case socket.assigns[:onboarding_path] do
      path when path in [:start, :improve] ->
        _ =
          Onboarding.save_draft(socket.assigns.current_user.id, %{
            "path" => to_string(path),
            "current_step" => socket.assigns.current_step,
            "company_id" =>
              if(path == :improve,
                do: socket.assigns[:current_company] && socket.assigns.current_company.id
              ),
            "submission_id" => socket.assigns[:improvement_submission_id],
            "form" => socket.assigns.company_form
          })

        socket

      _ ->
        socket
    end
  end
end
