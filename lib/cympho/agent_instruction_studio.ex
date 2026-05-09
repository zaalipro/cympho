defmodule Cympho.AgentInstructionStudio do
  @moduledoc """
  Deterministic instruction analysis for the agent configuration UI.

  The studio does not call a model. It compares the effective role contract,
  custom instructions, adapter posture, and role scenarios so owners can tune
  agents before bad runs create noisy issues.
  """

  alias Cympho.AgentPromptContractEval
  alias Cympho.AgentPromptContract
  alias Cympho.Agents.Agent

  @delivery_roles Agent.delivery_roles()

  @conflict_phrases [
    "skip comments",
    "no comments",
    "do not comment",
    "don't comment",
    "avoid comments",
    "skip tests",
    "no tests",
    "ignore review",
    "skip review",
    "merge without review",
    "close silently",
    "ignore governance",
    "ignore approval"
  ]

  @memory_terms [
    "owner-readable",
    "owner readable",
    "what happened",
    "current state",
    "next decision",
    "summarize",
    "summary",
    "concise"
  ]

  @pr_terms ["branch", "pull request", "pr", "task list", "checkbox", "github"]

  def analyze(agent_or_role, opts_or_instructions \\ [])

  def analyze(%Agent{} = agent, opts) when is_list(opts) do
    analyze(
      Keyword.get(opts, :role, agent.role),
      Keyword.get(opts, :instructions, agent.instructions),
      Keyword.merge([adapter: agent.adapter, config: agent.config || %{}], opts)
    )
  end

  def analyze(role, instructions), do: analyze(role, instructions, [])

  def analyze(role, instructions, opts) do
    role = normalize_role(role)
    instructions = to_string(instructions || "")
    contract = AgentPromptContract.build(role, instructions)
    adapter = opts |> Keyword.get(:adapter) |> normalize_adapter()
    audits = audits(role, instructions, contract, adapter)
    scenarios = scenarios(role, instructions, adapter)
    score = score(audits, scenarios)
    status = status(score, audits, scenarios)

    %{
      role: role,
      role_label: contract.role_label,
      status: status,
      status_label: status_label(status),
      score: score,
      summary: summary(status, role, score),
      effective_sections: effective_sections(role, instructions, contract, adapter, opts),
      audits: audits,
      scenarios: scenarios,
      eval_coverage: AgentPromptContractEval.coverage(role),
      patches: patches(role, adapter, contract),
      prompt_contract: contract
    }
  end

  defp audits(role, instructions, contract, adapter) do
    contract.checks
    |> Enum.map(fn check ->
      %{
        key: check_key(check.label),
        label: check.label,
        status: check.status,
        detail: check.detail,
        fix: contract_check_fix(check.status, role)
      }
    end)
    |> Kernel.++([
      memory_audit(instructions),
      conflict_audit(instructions),
      pr_audit(role, instructions),
      adapter_audit(adapter)
    ])
  end

  defp memory_audit(instructions) do
    hits = term_hits(instructions, @memory_terms)

    %{
      key: :memory_discipline,
      label: "Issue memory discipline",
      status: if(hits >= 2, do: :ok, else: :weak),
      detail:
        if hits >= 2 do
          "Custom instructions reinforce owner-readable summaries and next decisions."
        else
          "Custom instructions should explicitly ask for concise owner-readable summaries, current state, and next decision."
        end,
      fix:
        "Add the owner-readable summary patch so agents collapse routine work into useful issue memory."
    }
  end

  defp conflict_audit(instructions) do
    conflicts = phrase_hits(instructions, @conflict_phrases)

    %{
      key: :guardrail_conflicts,
      label: "Guardrail conflicts",
      status: if(conflicts == [], do: :ok, else: :attention),
      detail:
        if conflicts == [] do
          "No phrases found that tell the agent to skip comments, verification, review, or governance."
        else
          "Potentially unsafe instruction#{plural(length(conflicts))}: #{Enum.join(conflicts, ", ")}."
        end,
      fix: "Remove contradictory language and add the blocked-work guardrail patch."
    }
  end

  defp pr_audit(role, instructions) when role in @delivery_roles or role == :cto do
    hits = term_hits(instructions, @pr_terms)

    %{
      key: :pr_contract,
      label: "PR contract reinforcement",
      status: if(hits > 0, do: :ok, else: :weak),
      detail:
        if hits > 0 do
          "Custom instructions mention PR or branch discipline; the runtime prompt also injects the PR contract."
        else
          "The runtime prompt injects the PR contract, but custom instructions do not reinforce branch, title, body, or task-list quality."
        end,
      fix: "Add the PR quality patch when this agent creates or reviews GitHub PRs."
    }
  end

  defp pr_audit(_role, _instructions) do
    %{
      key: :pr_contract,
      label: "PR contract reinforcement",
      status: :neutral,
      detail: "Not required for this role unless it directly creates or reviews code PRs.",
      fix: "No PR-specific instruction is needed for this role by default."
    }
  end

  defp adapter_audit(adapter) do
    detail =
      case adapter do
        "claude_code" ->
          "Claude Code uses command/env routing. Keep provider/model details in runtime config or env."

        "codex" ->
          "Codex uses model selection rather than a runtime command override."

        "cursor" ->
          "Cursor uses local account access and model availability from the Cursor CLI."

        "openclaw" ->
          "OpenClaw should name provider, model, gateway, and harness clearly."

        "process" ->
          "Process adapters need command, args, cwd, and model forwarding to be explicit."

        _ ->
          "This adapter has no specific instruction profile yet."
      end

    %{
      key: :adapter_specificity,
      label: "Adapter specificity",
      status: if(adapter in ["http", nil, ""], do: :weak, else: :ok),
      detail: detail,
      fix:
        "Keep runtime mechanics out of business instructions; use the adapter fields below for commands and models."
    }
  end

  defp scenarios(:ceo, instructions, _adapter) do
    [
      scenario(
        :owner_intake,
        "Owner intake to strategy",
        "Turns a plain owner request into an explicit business outcome and first work packet.",
        term_hits(instructions, ["owner", "business status", "next decision"]) >= 1,
        "[owner_update] and [handoff]"
      ),
      scenario(
        :delegate_org,
        "Delegate to Product, Design, and CTO",
        "Routes product shaping, design work, and technical execution without losing accountability.",
        term_hits(instructions, ["product", "design", "cto", "delegate"]) >= 2,
        "[handoff]"
      ),
      blocked_scenario(instructions)
    ]
  end

  defp scenarios(:cto, instructions, _adapter) do
    [
      scenario(
        :split_work,
        "Split large work into child issues",
        "Creates scoped sub-issues with dependencies, acceptance criteria, and review order.",
        term_hits(instructions, ["split", "child", "acceptance", "dependencies", "review order"]) >=
          2,
        "[handoff]"
      ),
      scenario(
        :review_engineering,
        "Review delivery evidence",
        "Inspects PRs, artifacts, verification, gaps, and follow-up work before approval.",
        term_hits(instructions, ["review", "verification", "gaps", "follow-up"]) >= 2,
        "[review]"
      ),
      blocked_scenario(instructions)
    ]
  end

  defp scenarios(role, instructions, adapter) when role in @delivery_roles do
    [
      scenario(
        :delivery_package,
        "Deliver reviewable work",
        "Leaves files changed, verification, risks, current state, and next decision.",
        term_hits(instructions, ["files changed", "verification", "risks", "next decision"]) >= 2,
        "[delivery]"
      ),
      scenario(
        :pr_quality,
        "Create a clean PR",
        "Uses issue identifier in branch/title and a task-list PR description when a PR is created.",
        term_hits(instructions, @pr_terms) >= 1 or adapter in ["codex", "claude_code", "cursor"],
        "set_pr_url"
      ),
      blocked_scenario(instructions)
    ]
  end

  defp scenarios(_role, instructions, _adapter), do: [blocked_scenario(instructions)]

  defp blocked_scenario(instructions) do
    scenario(
      :blocked_work,
      "Escalate blocked work",
      "Explains cause, attempted fix, needs, current state, and next decision instead of stalling silently.",
      term_hits(instructions, ["blocked", "cause", "attempted fix", "needs"]) >= 1,
      "[blocked]"
    )
  end

  defp scenario(key, label, detail, reinforced?, required_signal) do
    %{
      key: key,
      label: label,
      status: if(reinforced?, do: :ok, else: :weak),
      detail: detail,
      required_signal: required_signal,
      fix:
        if(reinforced?,
          do: "Covered by role contract and custom instructions.",
          else:
            "Covered by the default role contract; add a patch below to reinforce it in custom instructions."
        )
    }
  end

  defp effective_sections(role, instructions, contract, adapter, opts) do
    [
      %{
        label: "Role playbook",
        source: "Injected",
        status: :ok,
        summary:
          "#{contract.role_label} mandate, allowed actions, anti-patterns, and quality bar.",
        preview: AgentPromptContract.prompt_block(role)
      },
      %{
        label: "Custom instructions",
        source: "Agent override",
        status: if(String.trim(instructions) == "", do: :neutral, else: :ok),
        summary: custom_instruction_summary(instructions),
        preview: if(String.trim(instructions) == "", do: "(none)", else: instructions)
      },
      %{
        label: "Completion contract",
        source: "Injected",
        status: contract.status,
        summary: "Required final tagged comment fields that feed issue memory and review gates.",
        preview: contract.required_template
      },
      %{
        label: "Action boundary",
        source: "Injected",
        status: :ok,
        summary: "Agents request side effects through validated cympho-actions JSON.",
        preview:
          "Use only allowed actions for the role. Leave comments, work products, handoffs, PR URLs, reviews, and approvals through cympho-actions."
      },
      runtime_section(adapter, opts)
    ]
    |> maybe_add_pr_section(role)
  end

  defp runtime_section(adapter, opts) do
    model = Keyword.get(opts, :model)
    command = Keyword.get(opts, :command)
    provider = Keyword.get(opts, :provider)

    preview =
      [
        command && "Command: #{command}",
        provider && "Provider: #{provider}",
        model && "Model: #{model}"
      ]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> case do
        [] -> "Runtime details come from the selected adapter configuration."
        lines -> Enum.join(lines, "\n")
      end

    %{
      label: "Runtime adapter",
      source: "Configuration",
      status: :ok,
      summary: "#{adapter_label(adapter)} runtime fields are configured below the studio.",
      preview: preview
    }
  end

  defp maybe_add_pr_section(sections, role) when role in @delivery_roles or role == :cto do
    sections ++
      [
        %{
          label: "PR quality contract",
          source: "Injected",
          status: :ok,
          summary: "Branch, title, and body requirements are injected for delivery/review roles.",
          preview:
            "Branch includes issue identifier. PR title starts with issue identifier. PR body includes summary, validation, risks, and task-list checkboxes."
        }
      ]
  end

  defp maybe_add_pr_section(sections, _role), do: sections

  defp patches(role, adapter, contract) do
    [
      owner_memory_patch(contract),
      role_patch(role),
      blocked_patch(),
      pr_patch(role),
      adapter_patch(adapter)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp owner_memory_patch(contract) do
    %{
      id: "owner-memory",
      title: "Owner-readable memory",
      tone: :primary,
      reason: "Reduces noisy issues and gives the owner a useful issue page.",
      body:
        "After every meaningful action, leave one concise owner-readable tagged comment using this shape:\n#{contract.required_template}\nDo not paste raw logs. Summarize what changed, how it was verified, remaining risks, current state, and the exact next decision."
    }
  end

  defp role_patch(:ceo) do
    %{
      id: "ceo-delegation",
      title: "CEO delegation",
      tone: :neutral,
      reason:
        "Keeps CEO issues readable when work is split across Product, Design, CTO, and engineers.",
      body:
        "When receiving an owner request, first state the business outcome, then delegate with `[handoff]` to Product, Design, and CTO as needed. Before closure, add `[owner_update] What happened: ... Business status: ... Current state: ... Next decision: ... Owner decision needed: ...`."
    }
  end

  defp role_patch(:cto) do
    %{
      id: "cto-review",
      title: "CTO split and review",
      tone: :neutral,
      reason: "Makes CTO decomposition and review auditable.",
      body:
        "For large work, split into child issues with acceptance criteria, dependencies, and review order. When reviewing, leave `[review] Verdict: accepted/request changes/blocked. What happened: ... Verification: ... Gaps: ... Follow-up issues: ... Next decision: ...`."
    }
  end

  defp role_patch(role) when role in @delivery_roles do
    %{
      id: "delivery-evidence",
      title: "Delivery evidence",
      tone: :neutral,
      reason: "Makes engineer/product/design output reviewable.",
      body:
        "Before `submit_review`, attach the work product or PR/reference and leave `[delivery] What happened: ... Files changed: ... Verification: ... Risks: ... Current state: ... Next decision: ...`. Include concrete file paths, commands/tests run, and any remaining risk."
    }
  end

  defp role_patch(_role), do: nil

  defp blocked_patch do
    %{
      id: "blocked-work",
      title: "Blocked work",
      tone: :danger,
      reason: "Prevents silent stalls and gives CTO/CEO something actionable.",
      body:
        "If blocked, do not keep retrying silently. Leave `[blocked] Cause: ... Attempted fix: ... Needs: ... Current state: ... Next decision: ...` and hand off to the role that can unblock it."
    }
  end

  defp pr_patch(role) when role in @delivery_roles or role == :cto do
    %{
      id: "pr-quality",
      title: "PR quality",
      tone: :neutral,
      reason: "Improves branch names, PR titles, and GitHub descriptions.",
      body:
        "When creating or updating a PR, include the issue identifier in the branch name and PR title. The PR body must include summary, validation, risks, linked issue, and a Markdown task list with completed and remaining work."
    }
  end

  defp pr_patch(_role), do: nil

  defp adapter_patch("codex") do
    %{
      id: "codex-model",
      title: "Codex model discipline",
      tone: :neutral,
      reason: "Keeps model choice in config instead of custom prose.",
      body:
        "Use the configured Codex model for execution. Do not mention runtime commands in business instructions; runtime model selection belongs in the Codex model field."
    }
  end

  defp adapter_patch("claude_code") do
    %{
      id: "claude-wrapper",
      title: "Claude wrapper discipline",
      tone: :neutral,
      reason: "Keeps cheap-provider routing explicit without polluting task instructions.",
      body:
        "Use the configured Claude-compatible command and environment for provider/model routing. Keep task comments focused on delivery evidence, not provider mechanics."
    }
  end

  defp adapter_patch("process") do
    %{
      id: "process-runtime",
      title: "Process runtime",
      tone: :neutral,
      reason: "Clarifies what belongs in runtime config for generic processes.",
      body:
        "Runtime command, cwd, args, and model forwarding belong in the Process adapter fields. Custom instructions should describe expected work quality, evidence, and handoff behavior."
    }
  end

  defp adapter_patch(_adapter), do: nil

  defp score(audits, scenarios) do
    penalties =
      (audits ++ scenarios)
      |> Enum.map(&status_penalty(&1.status))
      |> Enum.sum()

    max(0, 100 - penalties)
  end

  defp status(score, audits, scenarios) do
    cond do
      Enum.any?(audits ++ scenarios, &(&1.status == :attention)) -> :attention
      score < 80 -> :weak
      true -> :good
    end
  end

  defp status_label(:good), do: "Studio ready"
  defp status_label(:weak), do: "Needs tuning"
  defp status_label(:attention), do: "Guardrail risk"

  defp summary(:good, role, score) do
    "#{role_label(role)} instructions are ready with a #{score}/100 guardrail score."
  end

  defp summary(:weak, role, score) do
    "#{role_label(role)} defaults are active, but custom instructions should better reinforce key scenarios. Score #{score}/100."
  end

  defp summary(:attention, role, score) do
    "#{role_label(role)} custom instructions may conflict with Cympho guardrails. Score #{score}/100."
  end

  defp contract_check_fix(:ok, _role), do: "No change needed."

  defp contract_check_fix(:neutral, _role),
    do: "Optional: add a patch below to make the default behavior explicit."

  defp contract_check_fix(_status, role) do
    "Add the #{role_label(role)} required fields to custom instructions, or remove contradictory text."
  end

  defp custom_instruction_summary(instructions) do
    trimmed = String.trim(instructions)

    if trimmed == "" do
      "No custom override. Runtime uses the injected role playbook and contract."
    else
      "#{String.length(trimmed)} characters of custom guidance layered after the role playbook."
    end
  end

  defp check_key(label) do
    label
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
    |> String.to_atom()
  end

  defp term_hits(text, terms), do: length(phrase_hits(text, terms))

  defp phrase_hits(text, phrases) do
    normalized = String.downcase(to_string(text || ""))
    Enum.filter(phrases, &String.contains?(normalized, &1))
  end

  defp status_penalty(:attention), do: 25
  defp status_penalty(:weak), do: 10
  defp status_penalty(_status), do: 0

  defp normalize_adapter(adapter) when is_atom(adapter), do: Atom.to_string(adapter)
  defp normalize_adapter(adapter) when adapter in [nil, ""], do: "claude_code"
  defp normalize_adapter(adapter), do: to_string(adapter)

  defp adapter_label("claude_code"), do: "Claude Code"
  defp adapter_label("codex"), do: "Codex"
  defp adapter_label("cursor"), do: "Cursor"
  defp adapter_label("openclaw"), do: "OpenClaw"
  defp adapter_label("process"), do: "Process"
  defp adapter_label(adapter), do: adapter |> to_string() |> String.replace("_", " ")

  defp normalize_role(role) when is_atom(role), do: role

  defp normalize_role(role) do
    role
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
    |> case do
      "ceo" -> :ceo
      "cto" -> :cto
      "engineer" -> :engineer
      "product_manager" -> :product_manager
      "product" -> :product_manager
      "designer" -> :designer
      "design" -> :designer
      _ -> :engineer
    end
  end

  defp role_label(:ceo), do: "CEO"
  defp role_label(:cto), do: "CTO"
  defp role_label(:engineer), do: "Engineer"
  defp role_label(:product_manager), do: "Product"
  defp role_label(:designer), do: "Design"

  defp role_label(role),
    do: role |> to_string() |> String.replace("_", " ") |> String.capitalize()

  defp plural(1), do: ""
  defp plural(_), do: "s"
end
