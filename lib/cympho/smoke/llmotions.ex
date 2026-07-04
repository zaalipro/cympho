defmodule Cympho.Smoke.LLMotions do
  @moduledoc """
  Builds a focused LLMotions-backed smoke company and mission.

  The setup is intentionally deterministic and side-effect-light: it creates a
  new company, configures CEO/CTO as OpenAI-compatible LLMotions chat agents,
  configures engineer/QA as repo-capable process agents, stores the optional
  API key as an encrypted company secret, and creates one owner issue that the
  CEO must decompose in the live runtime.
  """

  alias Cympho.{
    AgentRuntimeCapabilities,
    Agents,
    Companies,
    Issues,
    RuntimeOperations,
    RuntimePreflight,
    RuntimeProfiles,
    Secrets,
    Workspaces
  }

  alias Cympho.Agents.Agent
  alias Cympho.Issues.Issue

  @endpoint "https://cli.llmotions.com/v1"
  @default_model "gemma-4-31b"
  @supported_models ~w(gemma-4-31b gemini-3.5-flash-low gemini-3.5-flash)
  @secret_key "LLMOTIONS_API_KEY"

  @type setup_opts :: [
          company_name: String.t(),
          issue_prefix: String.t(),
          model: String.t(),
          api_key: String.t() | nil,
          store_secret?: boolean(),
          cancel_seed_issues?: boolean(),
          focus?: boolean(),
          create_workspace?: boolean(),
          repo_cwd: String.t() | nil
        ]

  @spec setup(setup_opts()) :: {:ok, map()} | {:error, term()}
  def setup(opts \\ []) do
    model = opts |> Keyword.get(:model, @default_model) |> normalize_model()
    company_name = Keyword.get(opts, :company_name) || default_company_name()
    issue_prefix = Keyword.get(opts, :issue_prefix, "LMS")
    api_key = normalize_blank(Keyword.get(opts, :api_key))

    with {:ok, bootstrap} <-
           Companies.create_autonomous_company(%{
             name: company_name,
             goal_title: "Build Team Pulse launch tracker",
             blueprint: "software",
             issue_prefix: issue_prefix,
             engineer_count: 1,
             adapter: :openai_chat
           }),
         {:ok, project_workspace} <- maybe_create_project_workspace(bootstrap, opts),
         {:ok, configured_agents} <- configure_agents(bootstrap, model),
         {:ok, secret_status} <- maybe_store_secret(bootstrap.company.id, api_key, opts),
         :ok <- maybe_cancel_seed_issues(bootstrap.seed_issues, opts),
         {:ok, issue} <- create_team_pulse_issue(bootstrap, configured_agents.ceo),
         {:ok, focused_issue} <- maybe_focus_issue(issue, opts) do
      report = %{
        company: bootstrap.company,
        project: bootstrap.project,
        project_workspace: project_workspace,
        goal: bootstrap.goal,
        issue: focused_issue,
        agents: configured_agents,
        model: model,
        endpoint: @endpoint,
        secret_status: secret_status,
        focused_runtime_command:
          RuntimeOperations.focused_runtime_launch_command(focused_issue.id),
        preflight: RuntimePreflight.for_issue(focused_issue, autonomy_enabled?: true),
        expected_flow: expected_flow(),
        debug_matrix: debug_matrix(),
        model_comparison: model_comparison()
      }

      {:ok, Map.put(report, :text, render_report(report))}
    end
  end

  @spec render_report(map()) :: String.t()
  def render_report(report) when is_map(report) do
    issue = report.issue
    company = report.company
    agents = report.agents
    preflight = report.preflight

    """
    LLMotions smoke company ready

    Company:
      #{company.name} (#{company.slug})

    Provider:
      Endpoint: #{report.endpoint}
      Primary model: #{report.model}
      Secret: #{secret_status_label(report.secret_status)}

    Workspace:
      #{workspace_line(report.project_workspace)}

    Agents:
      CEO: #{agent_line(agents.ceo)}
      CTO: #{agent_line(agents.cto)}
      Engineer: #{agent_line(agents.engineer)}
      QA: #{agent_line(agents.qa)}

    Focus issue:
      #{issue.identifier || short_id(issue.id)} - #{issue.title}
      /issues/#{issue.id}

    Preflight:
      #{preflight.label} - #{preflight.summary}
      First action: #{first_action_line(preflight.first_action)}

    Focused runtime command:
      #{report.focused_runtime_command}

    Expected team flow:
    #{bullet_block(report.expected_flow)}

    Deep debug watchpoints:
    #{bullet_block(report.debug_matrix)}

    Model comparison:
    #{bullet_block(report.model_comparison)}
    """
    |> String.trim()
  end

  def endpoint, do: @endpoint
  def default_model, do: @default_model
  def supported_models, do: @supported_models
  def secret_key, do: @secret_key

  defp maybe_create_project_workspace(%{company: company, project: project}, opts) do
    if Keyword.get(opts, :create_workspace?, true) do
      repo_cwd =
        opts
        |> Keyword.get(:repo_cwd, File.cwd!())
        |> Path.expand()

      if File.dir?(repo_cwd) do
        Workspaces.create_project_workspace(%{
          company_id: company.id,
          project_id: project.id,
          name: "Local smoke repo",
          cwd: repo_cwd,
          repo_url: repo_cwd,
          repo_ref: current_git_ref(repo_cwd),
          default_ref: "main",
          is_primary: true,
          source_type: "local",
          visibility: "private",
          metadata: %{"created_by" => "llmotions_smoke"}
        })
      else
        {:error, {:repo_cwd_missing, repo_cwd}}
      end
    else
      {:ok, nil}
    end
  end

  defp configure_agents(%{company: company, project: project, agents: agents}, model) do
    ceo = find_agent!(agents, :ceo)
    cto = find_agent!(agents, :cto)
    engineer = find_agent!(agents, :engineer)

    with {:ok, ceo} <- configure_llmotions_agent(ceo, model, ceo_instructions()),
         {:ok, cto} <- configure_llmotions_agent(cto, model, cto_instructions()),
         {:ok, engineer} <- configure_repo_agent(engineer, "Repo-capable Engineer"),
         {:ok, qa} <- ensure_qa_agent(company.id, project.id, cto.id) do
      {:ok, %{ceo: ceo, cto: cto, engineer: engineer, qa: qa}}
    end
  rescue
    error -> {:error, error}
  end

  defp configure_llmotions_agent(%Agent{} = agent, model, extra_instructions) do
    Agents.update_agent(agent, %{
      adapter: :openai_chat,
      config: %{
        "endpoint" => @endpoint,
        "model" => model,
        "temperature" => 0.2,
        "timeout_sec" => 120
      },
      runtime_config: %{
        "profile_id" => profile_id_for_model(model),
        "env" => %{
          "LLMOTIONS_BASE_URL" => @endpoint,
          "LLMOTIONS_MODEL" => model
        }
      },
      max_concurrent_jobs: 1,
      instructions: append_instructions(agent.instructions, extra_instructions)
    })
  end

  defp configure_repo_agent(%Agent{} = agent, name) do
    Agents.update_agent(agent, %{
      name: name,
      adapter: :process,
      config:
        RuntimeProfiles.config("process-codex")
        |> Map.put("repo_capable", true),
      runtime_config:
        RuntimeProfiles.runtime_config("process-codex")
        |> Map.put("profile_id", "process-codex")
        |> Map.put("repo_capable", true),
      max_concurrent_jobs: 1,
      instructions: append_instructions(agent.instructions, repo_instructions())
    })
  end

  defp ensure_qa_agent(company_id, project_id, cto_id) do
    case Agents.list_agents_by_role(:qa_engineer, company_id) do
      [qa | _] ->
        configure_repo_agent(qa, qa.name || "QA Smoke Engineer")

      [] ->
        Agents.create_agent(%{
          company_id: company_id,
          project_id: project_id,
          parent_id: cto_id,
          name: "QA Smoke Engineer",
          title: "QA Smoke Engineer",
          role: :qa_engineer,
          status: :idle,
          adapter: :process,
          config:
            RuntimeProfiles.config("process-codex")
            |> Map.put("repo_capable", true),
          runtime_config:
            RuntimeProfiles.runtime_config("process-codex")
            |> Map.put("profile_id", "process-codex")
            |> Map.put("repo_capable", true),
          max_concurrent_jobs: 1,
          instructions: repo_instructions()
        })
    end
  end

  defp maybe_store_secret(_company_id, nil, _opts), do: {:ok, :missing}
  defp maybe_store_secret(_company_id, "", _opts), do: {:ok, :missing}

  defp maybe_store_secret(company_id, api_key, opts) do
    if Keyword.get(opts, :store_secret?, true) do
      case Secrets.get_secret_by_key(company_id, @secret_key, scope: "company") do
        {:ok, secret} ->
          with {:ok, _updated} <-
                 Secrets.update_secret(secret, %{
                   value: api_key,
                   description: "LLMotions OpenAI-compatible runtime credential"
                 }) do
            {:ok, :updated}
          end

        {:error, :not_found} ->
          with {:ok, _secret} <-
                 Secrets.create_secret(%{
                   company_id: company_id,
                   scope: "company",
                   key: @secret_key,
                   value: api_key,
                   description: "LLMotions OpenAI-compatible runtime credential"
                 }) do
            {:ok, :created}
          end
      end
    else
      {:ok, :not_stored}
    end
  end

  defp maybe_cancel_seed_issues(seed_issues, opts) do
    if Keyword.get(opts, :cancel_seed_issues?, true) do
      Enum.reduce_while(seed_issues, :ok, fn issue, :ok ->
        case Issues.transition_issue(issue, :cancelled) do
          {:ok, _} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    else
      :ok
    end
  end

  defp create_team_pulse_issue(%{company: company, project: project, goal: goal}, ceo) do
    Issues.create_issue(%{
      company_id: company.id,
      project_id: project.id,
      goal_id: goal.id,
      title: "Build Team Pulse launch tracker",
      description: team_pulse_description(),
      status: :todo,
      priority: :critical,
      assigned_role: "ceo",
      assignee_id: ceo.id,
      origin_type: "llmotions_smoke",
      request_depth: 0
    })
  end

  defp maybe_focus_issue(%Issue{} = issue, opts) do
    if Keyword.get(opts, :focus?, true) do
      Issues.prioritize_for_dispatch(issue)
    else
      {:ok, issue}
    end
  end

  defp find_agent!(agents, role) do
    Enum.find(agents, &(&1.role == role)) ||
      raise "autonomous company bootstrap did not create #{role}"
  end

  defp normalize_model(model) when model in @supported_models, do: model
  defp normalize_model(model) when is_binary(model) and model != "", do: model
  defp normalize_model(_), do: @default_model

  defp normalize_blank(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_blank(_), do: nil

  defp default_company_name do
    timestamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%d-%H%M%S")
    "LLMotions Smoke #{timestamp}"
  end

  defp profile_id_for_model("gemini-3.5-flash-low"),
    do: "openai-chat-llmotions-gemini-flash-low"

  defp profile_id_for_model("gemini-3.5-flash"), do: "openai-chat-llmotions-gemini-flash"
  defp profile_id_for_model(_), do: "openai-chat-llmotions-gemma"

  defp append_instructions(nil, extra), do: extra
  defp append_instructions("", extra), do: extra
  defp append_instructions(existing, extra), do: existing <> "\n\n" <> extra

  defp ceo_instructions do
    """
    LLMotions smoke run: act as CEO. Do not claim file edits. Your first turn
    should accept the owner request, create exactly one CTO-owned planning child
    with acceptance/evidence/verification/done fields, block the parent while
    waiting on CTO evidence, and leave a restart packet the owner can audit.

    Critical action-contract rule: if you emit `block_issue`, its `reason` JSON
    string must put each blocker field on its own line, using escaped newlines:
    Example valid JSON value:
    "[blocked] Cause: Waiting for CTO evidence.\\nAttempted fix: Created the CTO planning child issue with acceptance criteria, evidence, verification, done, dependencies, estimate, and review owner.\\nNeeds: CTO spec and child issue plan.\\nCurrent state: Parent is paused while CTO planning runs.\\nNext decision: CEO reviews CTO evidence and either approves, requests changes, or delegates more work.\\nRestart packet: Resume by reading the CTO child issue, latest comments, work products, verification notes, and remaining risks."
    Do not compress `Attempted fix`, `Needs`, `Current state`, `Next decision`,
    or `Restart packet` onto the same line as `Cause`; that rolls back the whole
    action batch.
    """
    |> String.trim()
  end

  defp cto_instructions do
    """
    LLMotions smoke run: act as CTO. Turn CEO strategy into implementation and
    QA issues, enforce repo-capable engineering evidence, request changes when
    proof is weak, and only approve after concrete verification is named.

    When you decompose and then block while waiting on engineer or QA evidence,
    `block_issue.reason` must be a multiline JSON string with these standalone
    labels in order: `[blocked] Cause:`, `Attempted fix:`, `Needs:`,
    `Current state:`, `Next decision:`, `Restart packet:`. Use `\\n` between
    labels inside JSON.
    """
    |> String.trim()
  end

  defp repo_instructions do
    """
    LLMotions smoke run: produce real repo evidence. Do not submit review until
    code/work-product evidence and focused verification are attached or the
    exact blocker is named.
    """
    |> String.trim()
  end

  defp team_pulse_description do
    """
    Owner request:
    Build a small usable internal app called Team Pulse launch tracker. A startup
    leadership team should be able to create launch items, assign owners, update
    status, see blocked work, and read a concise readiness summary before a
    weekly product launch decision.

    Business outcome:
    The owner can decide whether launch is ready, blocked, or needs escalation
    without reading raw engineering logs.

    Runtime constraint:
    CEO and CTO are LLMotions chat runtimes. They may plan, delegate, review,
    and emit Cympho actions. They must not claim local code edits, tests,
    branches, or PRs. Implementation and QA must go to repo-capable agents.

    CEO first turn:
    Create exactly one CTO-owned planning/spec child issue. Include acceptance
    criteria, evidence required, verification required, definition of done,
    dependency order, estimated minutes, and review owner. Block this parent
    while waiting on CTO evidence, and leave a tagged restart packet.

    CTO expected turn:
    Split the spec into implementation and QA work. Implementation should cover
    launch item creation, owner/status edits, blocked-work view, readiness
    summary, and empty/error states. QA should cover smoke checks for each path.

    Final CEO owner update:
    Name evidence inspected, verification, remaining risk, current state, next
    decision, owner decision needed, and restart packet.
    """
    |> String.trim()
  end

  defp expected_flow do
    [
      "CEO accepts owner request and creates exactly one CTO planning child.",
      "Parent issue moves to blocked only because delegated CTO evidence is pending.",
      "CTO creates implementation and QA children with concrete acceptance and verification.",
      "Engineer produces code/work-product evidence and submits to CTO review.",
      "QA records smoke coverage for create, edit, blocked view, summary, empty, and error states.",
      "CTO approves or requests changes with evidence inspected and verification named.",
      "CEO packages owner update and waits for owner accept/request-revision."
    ]
  end

  defp debug_matrix do
    [
      "Preflight: confirm LLMOTIONS_API_KEY is present, request URL ends in /chat/completions, and repo work is not assigned to chat-only agents.",
      "Orchestrator: watch orchestrator_session_started, heartbeat_runs, issue status transitions, and adapter errors.",
      "Actions: verify cympho-actions JSON creates child issues with company_id, parent_id, assigned_role, and assignee_id scoped correctly.",
      "Quality gates: reject thin engineer briefs, missing verification, missing PR/work-product evidence, and vague CTO reviews.",
      "Recovery: test no-output, timeout, stale checkout, stuck engineer reassignment, and owner revision loops.",
      "Security: search comments, logs, run metadata, and work products for provider key leakage after each run."
    ]
  end

  defp model_comparison do
    Enum.map(@supported_models, fn model ->
      "Run the same parent mission with #{model}; compare valid action rate, delegation quality, restart packet clarity, and unnecessary implementation claims."
    end)
  end

  defp secret_status_label(:created), do: "#{@secret_key} stored as encrypted company secret"

  defp secret_status_label(:updated),
    do: "#{@secret_key} rotated/updated as encrypted company secret"

  defp secret_status_label(:not_stored), do: "#{@secret_key} not stored by request"
  defp secret_status_label(:missing), do: "missing - add #{@secret_key} before dispatch"
  defp secret_status_label(other), do: inspect(other)

  defp workspace_line(nil),
    do: "not configured - repo-capable agents will use per-issue fallback workspaces"

  defp workspace_line(workspace) do
    "#{workspace.name} at #{workspace.cwd}"
  end

  defp agent_line(%Agent{} = agent) do
    repo_capable? = AgentRuntimeCapabilities.repo_delivery_capable?(agent)

    "#{agent.name} / #{agent.role} / #{agent.adapter} / #{profile_label(agent)} / repo_capable=#{repo_capable?}"
  end

  defp profile_label(%Agent{runtime_config: %{"profile_id" => profile_id}}), do: profile_id
  defp profile_label(_), do: "custom"

  defp first_action_line(nil), do: "none"
  defp first_action_line(%{label: label, detail: detail}), do: "#{label} - #{detail}"
  defp first_action_line(action), do: inspect(action)

  defp bullet_block(items) when is_list(items) do
    Enum.map_join(items, "\n", &"      - #{&1}")
  end

  defp short_id(id), do: id |> to_string() |> String.slice(0, 8)

  defp current_git_ref(cwd) do
    case System.cmd("git", ["rev-parse", "--abbrev-ref", "HEAD"], cd: cwd, stderr_to_stdout: true) do
      {branch, 0} -> String.trim(branch)
      _ -> nil
    end
  end
end
