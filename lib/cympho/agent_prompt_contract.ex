defmodule Cympho.AgentPromptContract do
  @moduledoc """
  Shared role-completion contract used by agent prompts and operator UI.

  The prompt contract is intentionally deterministic: it tells agents exactly
  which tagged comment shapes feed the issue digest, and lets owners preview
  whether an agent's custom instructions reinforce or weaken that contract.
  """

  alias Cympho.Agents.Agent

  @delivery_roles Agent.delivery_roles()
  @conflict_phrases [
    "ignore the playbook",
    "ignore playbook",
    "ignore role contract",
    "skip comments",
    "skip comment",
    "no comments",
    "do not comment",
    "don't comment",
    "avoid comments",
    "do not leave comments",
    "do not add comments",
    "skip tests",
    "no tests"
  ]

  @doc """
  Builds the full contract preview for a role and optional custom instructions.
  """
  def build(role, instructions \\ nil) do
    role = normalize_role(role)
    template = required_template(role)
    fields = required_fields(role)
    checks = checks(role, instructions, fields)
    status = status(checks, instructions)

    %{
      role: role,
      role_label: role_label(role),
      status: status,
      status_label: status_label(status),
      summary: summary(status, role),
      required_template: template,
      required_fields: fields,
      snippets: snippets(role),
      checks: checks
    }
  end

  @doc """
  Audits a concrete agent response/comment against the role's required final
  comment shape. Used by prompt eval fixtures and by future UI diagnostics.
  """
  def audit_response(role, body) do
    role = normalize_role(role)
    fields = required_fields(role)
    body = to_string(body)
    present_fields = Enum.filter(fields, &field_present?(body, &1))
    missing_fields = fields -- present_fields
    required_tag = List.first(fields)

    status =
      cond do
        missing_fields == [] ->
          :ok

        required_tag in missing_fields ->
          :missing

        true ->
          :attention
      end

    %{
      role: role,
      status: status,
      status_label: audit_status_label(status),
      present_fields: present_fields,
      missing_fields: missing_fields,
      required_template: required_template(role),
      summary: audit_summary(status, role, missing_fields)
    }
  end

  @doc """
  Markdown block injected into the runtime agent prompt.
  """
  def prompt_block(:ceo) do
    """
    ## Role completion contract
    You are accountable for the owner-visible business update.

    - When you delegate or split work, include a `[handoff]` or `[owner_update]` comment explaining the plan, current state, and who owns each next decision.
    - When CTO/product/design/engineering evidence is clear, add `[owner_update] What happened: ... Business status: shipped/not shipped. Current state: ... Next decision: ... Owner decision needed: ...` before closing parent work.
    - Parent issues with child work must not close silently. The owner should understand the final status without reading raw runs.
    - If the work is blocked, add `[blocked] Cause: ... Attempted fix: ... Needs: ... Current state: ... Next decision: ...`.
    """
    |> String.trim()
  end

  def prompt_block(:cto) do
    """
    ## Role completion contract
    You are accountable for technical decomposition and review.

    - When you split work, leave `[handoff]` with the child issue plan, dependencies, acceptance criteria, and review order.
    - When engineers submit work, leave `[review] Verdict: accepted/request changes/blocked. What happened: ... Verification: ... Gaps: ... Follow-up issues: ... Next decision: ...` before approving or requesting changes.
    - If evidence is missing, use `[blocked]` or `[review]` to say exactly which child issue, artifact, PR, or test is missing.
    - If the work is blocked, add `[blocked] Cause: ... Attempted fix: ... Needs: ... Current state: ... Next decision: ...`.
    """
    |> String.trim()
  end

  def prompt_block(role) when role in @delivery_roles do
    label =
      case role do
        :engineer -> "implementation"
        :product_manager -> "product/spec"
        :designer -> "design"
      end

    """
    ## Role completion contract
    You are accountable for #{label} delivery evidence.

    - Before `submit_review`, add `[delivery] What happened: ... Files changed: ... Verification: ... Risks: ... Current state: ... Next decision: ...`.
    - Attach a work product or PR/reference when the work creates anything reviewable.
    - If you cannot finish, add `[blocked] Cause: ... Attempted fix: ... Needs: ... Current state: ... Next decision: ...`.
    """
    |> String.trim()
  end

  def prompt_block(_role) do
    """
    ## Role completion contract
    Leave a tagged owner-readable comment whenever you move work forward: `[delivery]`, `[review]`, `[handoff]`, `[blocked]`, `[decision]`, or `[owner_update]`. Blocked notes must include Cause, Attempted fix, Needs, Current state, and Next decision.
    """
    |> String.trim()
  end

  def required_template(:ceo) do
    "[owner_update] What happened: ... Business status: shipped/not shipped. Current state: ... Next decision: ... Owner decision needed: ..."
  end

  def required_template(:cto) do
    "[review] Verdict: accepted/request changes/blocked. What happened: ... Verification: ... Gaps: ... Follow-up issues: ... Next decision: ..."
  end

  def required_template(role) when role in @delivery_roles do
    "[delivery] What happened: ... Files changed: ... Verification: ... Risks: ... Current state: ... Next decision: ..."
  end

  def required_template(_role) do
    "[delivery] What happened: ... Current state: ... Next decision: ... Evidence: ..."
  end

  defp required_fields(:ceo) do
    [
      "[owner_update]",
      "What happened",
      "Business status",
      "Current state",
      "Next decision",
      "Owner decision needed"
    ]
  end

  defp required_fields(:cto) do
    [
      "[review]",
      "Verdict",
      "What happened",
      "Verification",
      "Gaps",
      "Follow-up issues",
      "Next decision"
    ]
  end

  defp required_fields(role) when role in @delivery_roles do
    [
      "[delivery]",
      "What happened",
      "Files changed",
      "Verification",
      "Risks",
      "Current state",
      "Next decision"
    ]
  end

  defp required_fields(_role) do
    ["What happened", "Current state", "Next decision"]
  end

  defp snippets(role) do
    base = [
      %{
        label: "Blocked",
        tag: "[blocked]",
        body:
          "[blocked] Cause: ... Attempted fix: ... Needs: ... Current state: ... Next decision: ..."
      }
    ]

    role_snippets =
      case role do
        :ceo ->
          [
            %{label: "Owner update", tag: "[owner_update]", body: required_template(:ceo)},
            %{
              label: "Decision",
              tag: "[decision]",
              body:
                "[decision] What happened: ... Decision: ... Tradeoff: ... Current state: ... Next decision: ..."
            }
          ]

        :cto ->
          [
            %{label: "Review", tag: "[review]", body: required_template(:cto)},
            %{
              label: "Handoff",
              tag: "[handoff]",
              body:
                "[handoff] What happened: ... Child issues: ... Dependencies: ... Acceptance criteria: ... Review order: ..."
            }
          ]

        role when role in @delivery_roles ->
          [
            %{label: "Delivery", tag: "[delivery]", body: required_template(role)}
          ]

        _ ->
          [%{label: "Delivery", tag: "[delivery]", body: required_template(:engineer)}]
      end

    role_snippets ++ base
  end

  defp checks(role, instructions, fields) do
    text = instructions |> to_string() |> String.downcase()
    present? = String.trim(text) != ""
    conflicts = Enum.filter(@conflict_phrases, &String.contains?(text, &1))
    field_hits = Enum.count(fields, &String.contains?(text, String.downcase(&1)))

    [
      %{
        label: "Default role contract",
        status: :ok,
        detail: "#{role_label(role)} playbook is always injected into the runtime prompt."
      },
      %{
        label: "Custom override coverage",
        status:
          cond do
            !present? -> :neutral
            field_hits > 0 -> :ok
            true -> :weak
          end,
        detail:
          cond do
            !present? ->
              "No custom overrides. The default contract is the source of truth."

            field_hits > 0 ->
              "Custom instructions reference #{field_hits} contract field#{plural(field_hits)}."

            true ->
              "Custom instructions do not mention the required final-comment fields."
          end
      },
      %{
        label: "Conflict scan",
        status: if(conflicts == [], do: :ok, else: :attention),
        detail:
          if conflicts == [] do
            "No obvious instruction conflicts found."
          else
            "Potential conflict: #{Enum.join(conflicts, ", ")}."
          end
      }
    ]
  end

  defp status(checks, instructions) do
    cond do
      Enum.any?(checks, &(&1.status == :attention)) ->
        :attention

      String.trim(to_string(instructions)) != "" and Enum.any?(checks, &(&1.status == :weak)) ->
        :weak

      true ->
        :good
    end
  end

  defp summary(:good, role), do: "#{role_label(role)} contract is active and ready."

  defp summary(:weak, role) do
    "#{role_label(role)} contract is active, but custom overrides do not reinforce the required summary fields."
  end

  defp summary(:attention, _role) do
    "Custom instructions may conflict with the required issue-summary contract."
  end

  defp status_label(:good), do: "Good"
  defp status_label(:weak), do: "Weak override"
  defp status_label(:attention), do: "Check override"

  defp audit_status_label(:ok), do: "Contract satisfied"
  defp audit_status_label(:missing), do: "Tagged comment missing"
  defp audit_status_label(:attention), do: "Required fields missing"

  defp audit_summary(:ok, role, _missing_fields),
    do: "#{role_label(role)} response satisfies the prompt contract."

  defp audit_summary(:missing, role, missing_fields) do
    "#{role_label(role)} response is missing the required tag or fields: #{Enum.join(missing_fields, ", ")}."
  end

  defp audit_summary(:attention, role, missing_fields) do
    "#{role_label(role)} response is tagged but incomplete: #{Enum.join(missing_fields, ", ")}."
  end

  defp role_label(:ceo), do: "CEO"
  defp role_label(:cto), do: "CTO"
  defp role_label(:engineer), do: "Engineer"
  defp role_label(:product_manager), do: "Product"
  defp role_label(:designer), do: "Design"

  defp role_label(role),
    do: role |> to_string() |> String.replace("_", " ") |> String.capitalize()

  defp normalize_role(role) when is_atom(role), do: role

  defp normalize_role(role) when is_binary(role) do
    role
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
      _ -> :agent
    end
  end

  defp normalize_role(_role), do: :agent

  defp field_present?(body, field) do
    body
    |> String.downcase()
    |> String.contains?(field |> to_string() |> String.downcase())
  end

  defp plural(1), do: ""
  defp plural(_), do: "s"
end
