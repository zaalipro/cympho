defmodule CymphoWeb.OnboardingLive.Index do
  use CymphoWeb, :live_view

  alias Cympho.Adapters.CodexAdapter
  alias Cympho.Agents.Agent
  alias Cympho.Companies
  alias Cympho.Onboarding
  alias Cympho.Onboarding.Readiness

  # `label` names the step in the step list, `title` is the step's H1.
  @steps [
    %{id: :blueprint, label: "Template", title: "Start from a company template"},
    %{id: :company, label: "Company", title: "Name it and set a spending limit"},
    %{id: :team, label: "Team & AI", title: "Your team, and the AI it runs on"},
    %{id: :launch, label: "Review & launch", title: "Check everything before launch"},
    %{id: :ready, label: "Ready", title: "You're all set"}
  ]

  # Suggested leader names (B8): editable on the team step, blank keeps the role name.
  @leader_suggestions %{
    "ceo" => "Ada",
    "cto" => "Theo",
    "product_manager" => "Priya",
    "designer" => "Jun"
  }
  @leader_defaults %{
    "ceo" => "CEO",
    "cto" => "CTO",
    "product_manager" => "Product Lead",
    "designer" => "Design Lead"
  }

  # The template list shows this many until the owner searches or asks for all.
  @templates_shown 4

  @budget_message "Enter a spending limit above $0."
  @price_reason "Without it the spending limit can't stop Codex."

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
      # Onboarding draws its own bar and step list, so the root layout renders no rail or top bar.
      |> assign(:shell, :bare)
      |> assign(:steps, @steps)
      |> assign(:blueprints, blueprints)
      |> assign(:blueprint_query, "")
      |> assign(:filtered_blueprints, blueprints)
      |> assign(:onboarding_path, onboarding_path)
      |> assign(:current_step, current_step)
      |> assign(:step_error, nil)
      |> assign(:error_field, nil)
      |> assign(:all_templates, false)
      |> assign(:checking, false)
      |> assign(:dispatcher_on, Cympho.Orchestrator.Dispatcher.enabled?())
      |> assign(:bootstrap_result, nil)
      |> assign(:improvement_submission_id, improvement_submission_id)
      |> assign(:company_form, company_form)

    {:ok, socket}
  end

  @impl true
  def handle_event("next_step", _params, socket) do
    step = Enum.at(socket.assigns.steps, socket.assigns.current_step)

    # The launch step's own button launches; Continue never moves past it.
    launch_step = length(socket.assigns.steps) - 2

    case validate_step(step.id, socket.assigns.company_form) do
      :ok ->
        next = min(socket.assigns.current_step + 1, launch_step)

        {:noreply,
         socket
         |> assign(:current_step, max(next, socket.assigns.current_step))
         |> clear_error()
         |> persist_draft()}

      {:error, field, message} ->
        {:noreply, socket |> put_error(field, message) |> persist_draft()}
    end
  end

  def handle_event("prev_step", _params, socket) do
    {:noreply,
     socket
     |> assign(:current_step, max(socket.assigns.current_step - 1, 0))
     |> clear_error()
     |> persist_draft()}
  end

  # Finished steps in the step list go back; nothing jumps forward past a check.
  def handle_event("go_to_step", %{"step" => step}, socket) do
    case Integer.parse(to_string(step)) do
      {index, ""}
      when index >= 0 and index < socket.assigns.current_step and
             is_nil(socket.assigns.bootstrap_result) ->
        {:noreply, socket |> assign(:current_step, index) |> clear_error() |> persist_draft()}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("show_all_templates", _params, socket) do
    {:noreply, assign(socket, :all_templates, true)}
  end

  # B9: the server checks run only when the owner asks, in the background so
  # the page stays live while the test prompt is answered.
  def handle_event("check_readiness", _params, %{assigns: %{checking: true}} = socket),
    do: {:noreply, socket}

  def handle_event("check_readiness", _params, socket) do
    form = socket.assigns.company_form
    adapter = sanitize_adapter(form["adapter"])
    runtime = agent_runtime(form)

    {:noreply,
     socket
     |> assign(:checking, true)
     |> clear_error()
     |> start_async(:readiness, fn -> Readiness.check(adapter, runtime) end)}
  end

  def handle_event("skip", _params, socket) do
    if socket.assigns[:current_company] do
      {:noreply, push_navigate(socket, to: ~p"/issues")}
    else
      {:noreply, assign(socket, :step_error, "Finish setup to enter Cympho.")}
    end
  end

  # A readiness result only comes from the server's own check (B9), never from the form.
  def handle_event("update_company_form", %{"company" => params}, socket) do
    params =
      params
      |> Map.delete("readiness")
      |> maybe_apply_blueprint_defaults(socket.assigns.company_form)
      |> follow_company_name(socket.assigns.company_form)

    form = deep_merge_form(socket.assigns.company_form, params)

    {:noreply, socket |> assign(:company_form, form) |> clear_error() |> persist_draft()}
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

  @impl true
  def handle_async(:readiness, {:ok, result}, socket) do
    form = Map.put(socket.assigns.company_form, "readiness", result)

    {:noreply,
     socket |> assign(:checking, false) |> assign(:company_form, form) |> persist_draft()}
  end

  def handle_async(:readiness, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> assign(:checking, false)
     |> put_error(nil, "The checks could not run. Try again.")}
  end

  @allowed_adapters ~w(claude_code codex cursor http)

  defp launch_company(socket) do
    form = socket.assigns.company_form

    with :ok <- validate_step(:company, form),
         {:ok, budget_monthly_cents} <- parse_budget_monthly_cents(form) do
      attrs = %{
        "blueprint" => form["blueprint"],
        "name" => form["name"],
        "goal_title" => form["goal_title"],
        "project_name" => form["project_name"],
        "issue_prefix" => form["issue_prefix"],
        "engineer_count" => engineer_count(form),
        "engineer_names" => form["engineer_names"] || [],
        "leader_names" => form["leader_names"] || %{},
        "adapter" => sanitize_adapter(form["adapter"]),
        "agent_runtime" => agent_runtime(form),
        "role_runtimes" => role_runtimes_attrs(form),
        "owner_user_id" => socket.assigns.current_user.id,
        "budget_monthly_cents" => budget_monthly_cents
      }

      # A model/runtime mismatch, missing Codex prices or a failed check sends
      # the owner back to the team step (where the AI is picked) instead of
      # launching a company whose agents could never run.
      with :ok <- validate_runtime_compat(attrs),
           :ok <- validate_step(:team, form) do
        case create_company_safely(attrs) do
          {:ok, result} ->
            _ = Onboarding.clear_draft(socket.assigns.current_user.id)

            {:noreply,
             socket
             |> assign(:bootstrap_result, result)
             |> assign(:company_form, default_company_form())
             |> clear_error()
             |> assign(:current_step, 4)}

          {:error, :budget_required} ->
            {:noreply,
             socket
             |> assign(:current_step, 1)
             |> put_error(:budget_monthly_usd, @budget_message)
             |> persist_draft()}

          {:error, _reason} ->
            {:noreply,
             socket
             |> put_error(
               nil,
               "We couldn't launch the company. Review the company and AI settings, then try again."
             )
             |> persist_draft()}
        end
      else
        {:error, :runtime_incompatible, message} ->
          {:noreply,
           socket |> assign(:current_step, 2) |> put_error(nil, message) |> persist_draft()}

        {:error, field, message} ->
          {:noreply,
           socket |> assign(:current_step, 2) |> put_error(field, message) |> persist_draft()}
      end
    else
      {:error, field, message} ->
        {:noreply,
         socket |> assign(:current_step, 1) |> put_error(field, message) |> persist_draft()}
    end
  end

  defp put_error(socket, field, message) do
    socket |> assign(:step_error, message) |> assign(:error_field, field)
  end

  defp clear_error(socket), do: put_error(socket, nil, nil)

  @doc """
  The runtime every agent starts on (`agent_runtime` at launch, and what the
  readiness checks probe). Codex always names its model, so its prices (B10)
  are keyed by the model its runs report.
  """
  def agent_runtime(form) do
    adapter = sanitize_adapter(form["adapter"])
    model = present(form["runtime_model"])

    runtime = %{"command" => present(form["runtime_command"]) || "", "model" => model || ""}

    if adapter == "codex" do
      model = model || CodexAdapter.default_model()

      runtime
      |> Map.put("model", model)
      |> Map.put("pricing", %{
        model => %{
          "input_usd_per_mtok" => present(form["price_input"]) || "",
          "output_usd_per_mtok" => present(form["price_output"]) || ""
        }
      })
    else
      runtime
    end
  end

  @doc "True when every readiness check passes for the form's current runtime."
  def ready?(form) do
    Readiness.ready?(form["readiness"], sanitize_adapter(form["adapter"]), agent_runtime(form))
  end

  @doc "The Codex price error, or nil (B10): without both rates the limit can't stop Codex."
  def price_error(form) do
    cond do
      sanitize_adapter(form["adapter"]) != "codex" -> nil
      not valid_price?(form["price_input"]) -> "Enter the input price. #{@price_reason}"
      not valid_price?(form["price_output"]) -> "Enter the output price. #{@price_reason}"
      true -> nil
    end
  end

  defp valid_price?(value), do: Cympho.Finances.Pricing.valid_rate?(present(value) || "")

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

  # The team step already gives CEO and CTO a card each; the blueprint's role
  # summary then listed them again as the first two names.
  def other_roles_summary(blueprint) do
    blueprint.role_summary
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 in ["CEO", "CTO"]))
    |> Enum.join(", ")
  end

  # The prefix cap is 7 (not the schema's 10) because the launch engine
  # truncates prefixes to 7 characters; the name minimum is 3 because the
  # company slug derived from it must satisfy validate_length(:slug, min: 3).
  # Each error names the field it belongs to, so the form can point at it.
  defp validate_step(:company, form) do
    cond do
      String.trim(form["name"] || "") == "" ->
        {:error, :name, "Enter a company name."}

      String.length(String.trim(form["name"])) < 3 ->
        {:error, :name, "Use at least 3 characters for the company name."}

      String.trim(form["goal_title"] || "") == "" ->
        {:error, :goal_title, "Enter a first goal."}

      String.trim(form["project_name"] || "") == "" ->
        {:error, :project_name, "Enter a project name."}

      not Regex.match?(~r/^[A-Z]{2,7}$/, form["issue_prefix"] || "") ->
        {:error, :issue_prefix, "Use 2 to 7 capital letters for task IDs, like NW."}

      match?({:error, _}, parse_budget_monthly_cents(form)) ->
        {:error, :budget_monthly_usd, @budget_message}

      true ->
        :ok
    end
  end

  # B9/B10: Continue (and launch) need Codex prices and every readiness check.
  defp validate_step(:team, form) do
    cond do
      message = price_error(form) -> {:error, :price, message}
      not ready?(form) -> {:error, nil, "Every check must pass before you continue."}
      true -> :ok
    end
  end

  defp validate_step(_step, _form), do: :ok

  # Form collects whole USD dollars; engine stores cents and creates a block policy.
  def parse_budget_monthly_cents(form) when is_map(form) do
    raw = form["budget_monthly_usd"] || form[:budget_monthly_usd]

    case Integer.parse(String.trim(to_string(raw || ""))) do
      {usd, ""} when usd > 0 ->
        {:ok, usd * 100}

      _ ->
        {:error, @budget_message}
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

  def blueprint_short_name(name), do: String.replace_suffix(name, " company", "")

  # nil when the catalog's starter-issue counts differ, in which case the cards
  # keep printing their own.
  def shared_seed_issue_count(blueprints) do
    case blueprints |> Enum.map(& &1.seed_issue_count) |> Enum.uniq() do
      [count] -> count
      _ -> nil
    end
  end

  defp role_label(role) when is_binary(role) do
    role |> String.to_existing_atom() |> Agent.role_label()
  rescue
    ArgumentError -> Agent.role_label(role)
  end

  defp role_label(role), do: Agent.role_label(role)

  # ── AI provider helpers (team step) ────────────────────────────────────

  # "HTTP" named a transport, not a thing anyone has an account with, and it is
  # the one option whose endpoint and model live in advanced-only fields.
  def adapter_options do
    [
      {"Claude Code", "claude_code"},
      {"Codex (OpenAI)", "codex"},
      {"Cursor", "cursor"},
      {"Custom HTTP endpoint", "http"}
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

  # ── r3 page-local components (build-spec §2.6: page-only helpers) ────

  attr :id, :string, required: true
  attr :n, :integer, required: true
  attr :name, :string, required: true
  attr :value, :string, required: true
  attr :checked, :boolean, default: false
  slot :inner_block, required: true
  slot :line

  # An option row on paper (151): the radio sits right before its label.
  defp paper_opt(assigns) do
    ~H"""
    <div class="opt-w">
      <input
        class="opt-in"
        type="radio"
        id={@id}
        name={@name}
        value={@value}
        checked={@checked}
      />
      <label class="opt" for={@id}>
        <span class="on" aria-hidden="true">{@n}</span><span class="ot2">{render_slot(@inner_block)}<small :if={
          @line != []
        }>{render_slot(@line)}</small></span><span
          class="radio"
          aria-hidden="true"
        ></span>
      </label>
    </div>
    """
  end

  attr :people, :list, required: true

  # The crew card's tiles (001, 125); a role-only tile has no second line.
  defp crew_tiles(assigns) do
    ~H"""
    <ul class="crew">
      <li :for={person <- @people}>
        <span class="ct" aria-hidden="true">{initials(person.name)}</span><span class="cn">{person.name}<small :if={
          person.role
        }>{person.role}</small></span>
      </li>
    </ul>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :name, :string, required: true
  attr :value, :any, default: nil
  attr :error, :any, default: nil, doc: "the field's error message, tied by aria-describedby"
  attr :class, :any, default: nil
  attr :input_class, :string, default: nil
  attr :rest, :global, include: ~w(maxlength placeholder list inputmode)

  # A labelled capsule field (045, 024) with its own validation line.
  defp ob_field(assigns) do
    ~H"""
    <div class={["fld", @class]}>
      <label for={@id}>{@label}</label>
      <input
        id={@id}
        name={@name}
        type="text"
        value={@value}
        class={@input_class}
        autocomplete="off"
        aria-invalid={@error && "true"}
        aria-describedby={@error && @id <> "-e"}
        {@rest}
      />
      <p :if={@error} class="err" id={@id <> "-e"}><.r3_icon name="i-alert" />{@error}</p>
    </div>
    """
  end

  attr :message, :string, required: true

  defp ob_error(assigns) do
    ~H"""
    <p class="err" role="alert"><.r3_icon name="i-alert" />{@message}</p>
    """
  end

  # ── r3 view helpers ─────────────────────────────────────────────────

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_value), do: nil

  # The task-ID prefix ("NW") and the project ("{Company} app") follow the
  # company name until the owner sets them (spec P9 [LV]).
  defp follow_company_name(%{"name" => name} = params, form) when is_binary(name) do
    old = String.trim(form["name"] || "")
    new = String.trim(name)

    if new == "" or new == old do
      params
    else
      {prefix, project} =
        case Companies.autonomous_company_blueprint(form["blueprint"] || "software") do
          {:ok, blueprint} -> {blueprint.default_prefix, blueprint.project_name}
          {:error, :not_found} -> {nil, nil}
        end

      params
      |> follow(form, "issue_prefix", [prefix, name_prefix(old)], name_prefix(new))
      |> follow(form, "project_name", [project, "#{old} app"], "#{new} app")
    end
  end

  defp follow_company_name(params, _form), do: params

  defp follow(params, form, key, auto_values, value) do
    current = form[key]
    typed? = Map.has_key?(params, key) and params[key] != current

    if value != nil and not typed? and current in auto_values,
      do: Map.put(params, key, value),
      else: params
  end

  # Initials of up to three words ("Northwind Software" -> "NS"), or the first
  # two letters of a one-word name ("Acme" -> "AC").
  defp name_prefix(name) do
    prefix =
      case Regex.scan(~r/[A-Za-z]+/, name || "") |> List.flatten() do
        [word] -> String.slice(word, 0, 2)
        words -> words |> Enum.take(3) |> Enum.map_join(&String.first/1)
      end

    prefix = String.upcase(prefix)
    if Regex.match?(~r/^[A-Z]{2,7}$/, prefix), do: prefix
  end

  def leader_name(form, role) do
    present(get_in(form, ["leader_names", role])) || @leader_defaults[role]
  end

  @base_refs ~w(ceo cto product_lead design_lead)

  # Everyone the template hires, in the order the crew card lists them.
  defp crew(blueprint, form) do
    leaders =
      for {key, role} <- [
            ceo: :ceo,
            cto: :cto,
            product_manager: :product_manager,
            designer: :designer
          ] do
        key = Atom.to_string(key)
        %{key: key, name: leader_name(form, key), role: role_label(role)}
      end

    engineers =
      for index <- 1..engineer_count(form)//1 do
        %{key: "engineer", name: engineer_name_value(form, index), role: "Engineer"}
      end

    extras =
      for agent <- blueprint.launch_manifest["agent_roster"],
          agent["ref"] not in @base_refs and not String.starts_with?(agent["ref"], "engineer_") do
        %{key: agent["ref"], name: agent["name"], role: role_label(agent["role"])}
      end

    leaders ++ engineers ++ extras
  end

  # Before the team is named, the crew card shows the roles.
  defp crew_roles(blueprint, form) do
    Enum.map(crew(blueprint, form), &%{&1 | name: &1.role, role: nil})
  end

  defp initials(text) do
    case String.split(text) do
      [first, second | _] -> String.first(first) <> String.first(second)
      [word] -> String.slice(word, 0, 2)
      [] -> "?"
    end
    |> String.upcase()
  end

  defp also_on_team(crew) do
    crew
    |> Enum.reject(&(&1.key in ["ceo", "cto", "engineer"]))
    |> Enum.map(&"#{&1.name} (#{&1.role})")
    |> join_and()
  end

  defp team_line(crew) do
    {engineers, others} = Enum.split_with(crew, &(&1.key == "engineer"))

    engineer_part =
      case engineers do
        [] -> []
        [one] -> ["#{one.name} (Engineer)"]
        many -> ["#{many |> Enum.map(& &1.name) |> join_and()} (Engineers)"]
      end

    {leaders, extras} = Enum.split_with(others, &(&1.key in Map.keys(@leader_defaults)))

    (Enum.map(leaders, &"#{&1.name} (#{&1.role})") ++
       engineer_part ++ Enum.map(extras, &"#{&1.name} (#{&1.role})"))
    |> Enum.join(", ")
  end

  defp join_and([]), do: ""
  defp join_and([one]), do: one

  defp join_and(items) do
    {init, [last]} = Enum.split(items, -1)
    Enum.join(init, ", ") <> " and " <> last
  end

  # Who picks up task 1: the first seed task's assignee in the template.
  defp first_task_owner(blueprint, crew) do
    ref =
      case blueprint.launch_manifest["seed_work"] do
        [first | _] -> first["assignee_ref"]
        _ -> "ceo"
      end

    key =
      case ref do
        "product_lead" -> "product_manager"
        "design_lead" -> "designer"
        "first_engineer" -> "engineer"
        other -> other
      end

    Enum.find(crew, &(&1.key == key)) || Enum.find(crew, &(&1.key == "cto")) ||
      List.first(crew)
  end

  defp visible_templates(filtered, form, all?, query) do
    if all? or query != "" do
      filtered
    else
      shown = Enum.take(filtered, @templates_shown)
      selected = Enum.find(filtered, &(&1.key == form["blueprint"]))

      if selected && selected not in shown, do: shown ++ [selected], else: shown
    end
  end

  defp provider_name("codex"), do: "Codex"
  defp provider_name(_adapter), do: "Claude Code"

  # The three readiness lines for the form's runtime (build-spec §9).
  defp readiness_view(form, checking?) do
    adapter = sanitize_adapter(form["adapter"])
    runtime = agent_runtime(form)
    result = form["readiness"]
    current? = not checking? and Readiness.current?(result, adapter, runtime)
    installed = current? and result["installed"] == true
    signed_in = current? and result["signed_in"] == true
    priceable = Readiness.priceable?(adapter, runtime)
    program = Readiness.program(adapter, runtime) || adapter

    rows = [
      {"Installed", current? && installed,
       cond do
         installed -> "found the #{program} program on this server"
         current? -> "the #{program} program was not found on this server"
         true -> "looks for the #{program} program on this server"
       end},
      {"Signed in", current? && signed_in,
       cond do
         signed_in ->
           "a one-line test prompt was answered"

         current? and installed ->
           "The test prompt was refused. Sign in to #{provider_name(adapter)} on the server, then check again."

         current? ->
           "needs the program first"

         true ->
           "sends a one-line test prompt"
       end},
      {"Can be priced", priceable,
       cond do
         priceable and adapter == "codex" -> "you entered its prices"
         priceable -> "it reports the cost of every run"
         adapter == "codex" -> "enter its input and output prices above"
         true -> "it reports no usage, so the spending limit can't stop it"
       end}
    ]

    %{
      current?: current?,
      rows:
        Enum.map(rows, fn {label, state, text} ->
          kind =
            cond do
              state == true -> :done
              label == "Can be priced" or current? -> :stopped
              true -> :idle
            end

          %{label: label, kind: kind, text: text}
        end),
      heading:
        cond do
          checking? -> "Checking this server…"
          current? and installed and signed_in and priceable -> "Ready on this server"
          current? -> "Not ready on this server"
          true -> "Not checked yet"
        end,
      action:
        cond do
          checking? -> "Checking…"
          not current? -> "Check"
          not (installed and signed_in) -> "Check again"
          true -> nil
        end,
      fix?: current? and not (installed and signed_in)
    }
  end

  defp user_initials(%{name: name}) when is_binary(name) and name != "", do: initials(name)
  defp user_initials(_user), do: "Me"

  defp step_state(index, current) do
    cond do
      index < current -> :done
      index == current -> :current
      true -> :todo
    end
  end

  defp default_company_form do
    %{
      "blueprint" => "software",
      "name" => "Autonomous Software Company",
      "goal_title" => "Build and run the business autonomously",
      "improvement_details" => "",
      "project_name" => "Company OS",
      "issue_prefix" => "LLM",
      # Whole USD; converted to cents and a blocking BudgetPolicy at launch.
      "budget_monthly_usd" => "100",
      "engineer_count" => "2",
      "engineer_names" => [],
      "leader_names" => @leader_suggestions,
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
