defmodule Cympho.BoardApprovals do
  @moduledoc """
  The BoardApprovals context for managing board-level governance workflows.
  """

  import Ecto.Query, warn: false
  alias Cympho.Repo
  alias Cympho.BoardApprovals.{BoardApproval, BoardApprovalVote}
  alias Cympho.GovernanceAuditLogs
  alias Cympho.Decisions
  alias Cympho.AuditTrail.Instrumenter

  @nil_uuid "00000000-0000-0000-0000-000000000000"

  @doc """
  Returns the list of board approvals.
  """
  def list_board_approvals(opts \\ %{}) do
    query = from(ba in BoardApproval, order_by: [desc: ba.inserted_at])

    query =
      Enum.reduce(opts, query, fn
        {:company_id, id}, q ->
          where(q, [ba], ba.company_id == ^id)

        {:status, status}, q ->
          where(q, [ba], ba.status == ^status)

        {:category, category}, q ->
          where(q, [ba], ba.category == ^category)

        {:pending, true}, q ->
          where(q, [ba], ba.status == "pending")

        _, q ->
          q
      end)

    Repo.all(query)
    |> Repo.preload([:requested_by, :votes, :company])
  end

  @doc """
  Gets a single board approval.
  """
  def get_board_approval!(id) do
    Repo.get!(BoardApproval, id)
    |> Repo.preload([:requested_by, {:votes, [:user]}, :company])
  end

  def get_board_approval(id) do
    case Repo.get(BoardApproval, id) do
      nil -> {:error, :not_found}
      approval -> {:ok, Repo.preload(approval, [:requested_by, :company, {:votes, [:user]}])}
    end
  end

  @doc """
  Creates a board approval proposal.
  """
  def create_board_approval(attrs, actor \\ nil) do
    %BoardApproval{}
    |> BoardApproval.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, approval} ->
        approval = Repo.preload(approval, [:requested_by, :company])

        GovernanceAuditLogs.log_action(
          "board_proposal_created",
          actor || approval.requested_by,
          "Board approval requested: #{approval.title}",
          resource: approval,
          reasoning: approval.description,
          metadata: %{
            category: approval.category,
            proposal_data: approval.proposal_data
          }
        )

        Phoenix.PubSub.broadcast(
          Cympho.PubSub,
          "company:#{approval.company_id}:approvals",
          {:board_approval_created, approval}
        )

        {:ok, approval}

      error ->
        error
    end
  end

  @doc """
  Records a board member vote on a proposal.
  """
  def cast_vote(board_approval_id, user_id, vote, reasoning \\ nil) do
    attrs = %{
      board_approval_id: board_approval_id,
      user_id: user_id,
      vote: vote,
      reasoning: reasoning
    }

    %BoardApprovalVote{}
    |> BoardApprovalVote.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, vote_record} ->
        board_approval = get_board_approval!(board_approval_id)

        GovernanceAuditLogs.log_action(
          "board_vote_cast",
          {"user", user_id},
          "Board vote cast: #{vote} on #{board_approval.title}",
          resource: board_approval,
          reasoning: reasoning,
          metadata: %{
            vote: vote,
            board_approval_id: board_approval_id
          }
        )

        # Record audit event for board vote
        _ = Instrumenter.record_board_vote(
          board_approval,
          vote,
          "user",
          user_id
        )

        Phoenix.PubSub.broadcast(
          Cympho.PubSub,
          "company:#{board_approval.company_id}:approvals",
          {:board_vote_cast, vote_record}
        )

        check_auto_approve(board_approval)

        {:ok, vote_record}

      error ->
        error
    end
  end

  @doc """
  Resolves a board approval proposal.
  """
  def resolve_board_approval(board_approval_id, status, attrs, actor) do
    board_approval = Repo.get!(BoardApproval, board_approval_id)

    board_approval
    |> BoardApproval.approve_changeset(Map.put(attrs, :status, status))
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        updated = Repo.preload(updated, [:requested_by, :company])

        GovernanceAuditLogs.log_action(
          "board_decision",
          actor,
          "Board approval #{status}: #{updated.title}",
          resource: updated,
          reasoning: Map.get(attrs, :decision_reasoning),
          metadata: %{
            status: status,
            vote_summary: BoardApproval.vote_summary(updated)
          }
        )

        Decisions.record_board_decision(updated, actor)

        Phoenix.PubSub.broadcast(
          Cympho.PubSub,
          "company:#{updated.company_id}:approvals",
          {:board_approval_resolved, updated}
        )

        Phoenix.PubSub.broadcast(
          Cympho.PubSub,
          "system:board_approvals",
          {:board_approval_resolved, updated}
        )

        # Execution is handled by BoardApprovalActionExecutor GenServer
        # to prevent race conditions and ensure consistent async processing

        {:ok, updated}

      error ->
        error
    end
  end

  @doc """
  Cancels a pending board approval.
  """
  def cancel_board_approval(board_approval_id, actor \\ nil) do
    board_approval = Repo.get!(BoardApproval, board_approval_id)

    if board_approval.status == "pending" do
      board_approval
      |> Ecto.Changeset.change(%{status: "cancelled"})
      |> Repo.update()
      |> case do
        {:ok, updated} ->
          GovernanceAuditLogs.log_action(
            "board_proposal_cancelled",
            actor,
            "Board approval cancelled: #{updated.title}",
            resource: updated
          )

          Phoenix.PubSub.broadcast(
            Cympho.PubSub,
            "company:#{updated.company_id}:approvals",
            {:board_approval_cancelled, updated}
          )

          Phoenix.PubSub.broadcast(
            Cympho.PubSub,
            "system:board_approvals",
            {:board_approval_cancelled, updated}
          )

          {:ok, updated}

        error ->
          error
      end
    else
      {:error, :not_pending}
    end
  end

  @doc """
  Checks and updates expired board approvals.
  """
  def check_expired_approvals do
    from(ba in BoardApproval,
      where: ba.status == "pending" and ba.review_deadline < ^DateTime.utc_now()
    )
    |> Repo.update_all(set: [status: "expired"])
  end

  @doc """
  Subscribes to board approval events.
  """
  def subscribe(company_id) do
    Phoenix.PubSub.subscribe(Cympho.PubSub, "company:#{company_id}:approvals")
  end

  @doc """
  Checks whether a given governance category requires board approval
  for the company based on its governance_config.

  Returns true if the category is listed in the company's required approvals.
  Defaults to false when no governance_config is set.
  """
  def governance_required?(%Cympho.Companies.Company{} = company, category) do
    config = Map.get(company, :governance_config) || %{}

    required =
      Map.get(config, "categories") ||
        Map.get(config, "required_approvals") ||
        Map.get(config, :required_approvals) || []

    category in required
  end

  def governance_required?(company_id, category) when is_binary(company_id) do
    case Cympho.Repo.get(Cympho.Companies.Company, company_id) do
      nil -> false
      company -> governance_required?(company, category)
    end
  end

  # --- Agent Approval Workflows ---

  @doc """
  Proposes hiring a new agent. If board approval is required for the company,
  creates a pending proposal. Otherwise, hires the agent directly.
  """
  def propose_agent_hire(company_id, agent_attrs, requested_by \\ nil) do
    if governance_required?(company_id, "agent_hire") do
      create_board_approval(
        %{
          title: "Hire Agent: #{agent_attrs["name"] || agent_attrs[:name] || "Unnamed"}",
          description: "Request to hire a new agent.",
          category: "agent_hire",
          company_id: company_id,
          requested_by_agent_id: extract_agent_id(requested_by),
          proposal_data: %{
            "agent_attrs" => agent_attrs
          },
          review_deadline: DateTime.utc_now() |> DateTime.add(7 * 24 * 3600, :second)
        },
        requested_by
      )
    else
      Cympho.Agents.create_agent(agent_attrs)
    end
  end

  @doc """
  Proposes changing an agent's role. If board approval is required,
  creates a pending proposal. Otherwise, updates the role directly.
  """
  def propose_role_change(company_id, agent_id, new_role, requested_by \\ nil) do
    if governance_required?(company_id, "agent_promotion") do
      with {:ok, agent} <- Cympho.Agents.get_agent(agent_id) do
        create_board_approval(
          %{
            title: "Role Change: #{agent.name} → #{new_role}",
            description:
              "Request to change role of agent #{agent.name} from #{agent.role} to #{new_role}.",
            category: "agent_promotion",
            company_id: company_id,
            requested_by_agent_id: extract_agent_id(requested_by),
            proposal_data: %{
              "agent_id" => agent_id,
              "new_role" => to_string(new_role),
              "current_role" => to_string(agent.role)
            },
            review_deadline: DateTime.utc_now() |> DateTime.add(7 * 24 * 3600, :second)
          },
          requested_by
        )
      end
    else
      with {:ok, agent} <- Cympho.Agents.get_agent(agent_id) do
        Cympho.Agents.update_agent(agent, %{role: new_role})
      end
    end
  end

  # --- Budget Approval Workflows ---

  @doc """
  Proposes a budget increase. If board approval is required, creates a
  pending proposal. Otherwise, applies the change directly.
  """
  def propose_budget_change(company_id, budget_id, new_limit, requested_by \\ nil) do
    if governance_required?(company_id, "budget_increase") and
         budget_is_increase?(budget_id, new_limit) do
      create_board_approval(
        %{
          title: "Budget Increase: #{budget_id}",
          description: "Request to increase budget limit.",
          category: "budget_increase",
          company_id: company_id,
          requested_by_agent_id: extract_agent_id(requested_by),
          proposal_data: %{
            "action" => "update_budget",
            "budget_id" => budget_id,
            "new_limit" => new_limit,
            "update_attrs" => %{"limit_amount" => new_limit}
          },
          review_deadline: DateTime.utc_now() |> DateTime.add(7 * 24 * 3600, :second)
        },
        requested_by
      )
    else
      apply_budget_change(company_id, budget_id, new_limit)
    end
  end

  defp budget_is_increase?(budget_id, new_limit) do
    case Cympho.Budgets.get_budget(budget_id) do
      {:ok, budget} ->
        new_dec = parse_decimal(new_limit)
        new_dec != nil and Decimal.gt?(new_dec, budget.limit_amount || Decimal.new(0))

      {:error, :not_found} ->
        true
    end
  end

  defp parse_decimal(nil), do: nil
  defp parse_decimal(%Decimal{} = d), do: d
  defp parse_decimal(v) when is_integer(v), do: Decimal.new(v)
  defp parse_decimal(v) when is_float(v), do: Decimal.from_float(v)
  defp parse_decimal(v) when is_binary(v), do: Decimal.new(v)

  @doc """
  Proposes a company config change requiring board approval.
  """
  def propose_config_change(company_id, config_key, config_value, requested_by \\ nil) do
    update_attrs = %{String.to_atom(config_key) => config_value}

    if governance_required?(company_id, "policy_change") do
      create_board_approval(
        %{
          title: "Config Change: #{config_key}",
          description: "Request to change company config #{config_key}.",
          category: "policy_change",
          company_id: company_id,
          requested_by_agent_id: extract_agent_id(requested_by),
          proposal_data: %{
            "action" => "update_company",
            "company_id" => company_id,
            "config_key" => config_key,
            "config_value" => config_value,
            "update_attrs" => stringify_keys(update_attrs)
          },
          review_deadline: DateTime.utc_now() |> DateTime.add(7 * 24 * 3600, :second)
        },
        requested_by
      )
    else
      apply_config_change(company_id, config_key, config_value)
    end
  end

  @doc """
  Proposes a strategic initiative requiring board review.
  Strategy approvals cover major plan changes, new directions, and
  significant pivots that require board-level visibility and sign-off.
  """
  def propose_strategic_initiative(
        company_id,
        title,
        description,
        proposal_data,
        requested_by \\ nil
      ) do
    if governance_required?(company_id, "strategic_initiative") do
      create_board_approval(
        %{
          title: title,
          description: description,
          category: "strategic_initiative",
          company_id: company_id,
          requested_by_agent_id: extract_agent_id(requested_by),
          proposal_data: proposal_data,
          review_deadline: DateTime.utc_now() |> DateTime.add(14 * 24 * 3600, :second)
        },
        requested_by
      )
    else
      {:ok, :auto_approved}
    end
  end

  defp apply_budget_change(company_id, budget_id, new_limit) do
    company = Cympho.Repo.get!(Cympho.Companies.Company, company_id)
    config = company.governance_config || %{}
    budgets = Map.get(config, "budgets", %{})
    updated_budgets = Map.put(budgets, budget_id, new_limit)
    updated_config = Map.put(config, "budgets", updated_budgets)

    result =
      company
      |> Ecto.Changeset.change(%{governance_config: updated_config})
      |> Cympho.Repo.update()

    case result do
      {:ok, updated} ->
        GovernanceAuditLogs.log_action(
          "budget_change_applied_directly",
          {"system", @nil_uuid},
          "Budget config applied directly (no governance required): #{budget_id}",
          resource: updated,
          metadata: %{budget_id: budget_id, new_limit: new_limit}
        )

        {:ok, updated}

      error ->
        error
    end
  end

  defp apply_config_change(company_id, config_key, config_value) do
    company = Cympho.Repo.get!(Cympho.Companies.Company, company_id)
    config = company.governance_config || %{}
    updated_config = Map.put(config, config_key, config_value)

    result =
      company
      |> Ecto.Changeset.change(%{governance_config: updated_config})
      |> Cympho.Repo.update()

    case result do
      {:ok, updated} ->
        GovernanceAuditLogs.log_action(
          "config_change_applied_directly",
          {"system", @nil_uuid},
          "Company config applied directly (no governance required): #{config_key}",
          resource: updated,
          metadata: %{config_key: config_key}
        )

        {:ok, updated}

      error ->
        error
    end
  end

  defp extract_agent_id(nil), do: nil
  defp extract_agent_id(%Cympho.Agents.Agent{id: id}), do: id
  defp extract_agent_id(id) when is_binary(id), do: id
  defp extract_agent_id({"agent", id}), do: id
  defp extract_agent_id(_), do: nil

  defp check_auto_approve(%BoardApproval{} = board_approval) do
    threshold_opts = load_threshold_opts(board_approval.company_id)

    if BoardApproval.approval_threshold_met?(board_approval, threshold_opts) do
      resolve_board_approval(
        board_approval.id,
        "approved",
        %{
          decision_reasoning: "Auto-approved based on board vote threshold"
        },
        {"system", @nil_uuid}
      )
    end
  end

  defp load_threshold_opts(company_id) do
    company = Cympho.Repo.get(Cympho.Companies.Company, company_id)
    config = (company && company.governance_config) || %{}

    [
      threshold_type: Map.get(config, "threshold_type", "percentage"),
      threshold_value: Map.get(config, "threshold_value", 0.6)
    ]
  end

  @doc """
  Executes the approved action for a board approval.
  Called by BoardApprovalActionExecutor GenServer for async execution.
  """
  def execute_approved_action(%BoardApproval{status: "approved"} = board_approval) do
    case board_approval.category do
      "agent_hire" ->
        trigger_agent_hire(board_approval)

      "agent_termination" ->
        trigger_agent_termination(board_approval)

      "agent_promotion" ->
        trigger_agent_promotion(board_approval)

      "budget_increase" ->
        trigger_budget_increase(board_approval)

      "policy_change" ->
        trigger_policy_change(board_approval)

      "principal_permission" ->
        trigger_permission_grant(board_approval)

      "strategic_initiative" ->
        trigger_strategic_initiative(board_approval)

      _ ->
        :ok
    end
  end

  def execute_approved_action(_), do: :ok

  defp trigger_agent_hire(board_approval) do
    proposal_data = board_approval.proposal_data || %{}

    agent_attrs =
      Map.get(proposal_data, "attrs") || Map.get(proposal_data, "agent_attrs") ||
        Map.get(proposal_data, "agent_params") || %{}

    case Cympho.Agents.do_create_agent(agent_attrs) do
      {:ok, agent} ->
        GovernanceAuditLogs.log_action(
          "agent_hire_executed",
          {"board_approval", board_approval.id},
          "Agent hired via board approval: #{agent.name}",
          resource: agent,
          metadata: %{board_approval_id: board_approval.id, agent_id: agent.id}
        )

        Phoenix.PubSub.broadcast(
          Cympho.PubSub,
          "company:#{board_approval.company_id}:governance",
          {:agent_hire_approved, board_approval.id, agent}
        )

        {:ok, agent}

      {:error, changeset} ->
        GovernanceAuditLogs.log_action(
          "agent_hire_failed",
          {"board_approval", board_approval.id},
          "Agent hire failed after board approval",
          metadata: %{board_approval_id: board_approval.id, errors: inspect(changeset.errors)}
        )

        {:error, changeset}
    end
  end

  defp trigger_agent_termination(board_approval) do
    agent_id = get_in(board_approval.proposal_data, ["agent_id"])

    if agent_id do
      case Cympho.Agents.get_agent(agent_id) do
        {:ok, agent} ->
          Cympho.Agents.do_update_agent(agent, %{status: :offline})

          GovernanceAuditLogs.log_action(
            "agent_termination_executed",
            {"board_approval", board_approval.id},
            "Agent terminated via board approval: #{agent.name}",
            resource: agent,
            metadata: %{board_approval_id: board_approval.id, agent_id: agent_id}
          )

          Phoenix.PubSub.broadcast(
            Cympho.PubSub,
            "company:#{board_approval.company_id}:governance",
            {:agent_termination_approved, board_approval.id, agent_id}
          )

          {:ok, agent}

        {:error, _} ->
          {:error, :agent_not_found}
      end
    end
  end

  defp trigger_agent_promotion(board_approval) do
    agent_id = get_in(board_approval.proposal_data, ["agent_id"])
    new_role = get_in(board_approval.proposal_data, ["new_role"])

    if agent_id != nil and new_role != nil do
      case Cympho.Agents.get_agent(agent_id) do
        {:ok, agent} ->
          case Cympho.Agents.do_update_agent(agent, %{role: new_role}) do
            {:ok, updated} ->
              GovernanceAuditLogs.log_action(
                "agent_promotion_executed",
                {"board_approval", board_approval.id},
                "Agent #{agent.name} promoted to #{new_role}",
                resource: updated,
                metadata: %{
                  board_approval_id: board_approval.id,
                  agent_id: agent_id,
                  new_role: new_role
                }
              )

              Phoenix.PubSub.broadcast(
                Cympho.PubSub,
                "company:#{board_approval.company_id}:governance",
                {:agent_promotion_approved, board_approval.id, agent_id, new_role}
              )

              {:ok, updated}

            error ->
              error
          end

        {:error, _} ->
          {:error, :agent_not_found}
      end
    end
  end

  defp trigger_budget_increase(board_approval) do
    action = get_in(board_approval.proposal_data, ["action"])
    actor = nil
    meta = %{board_approval_id: board_approval.id}

    case action do
      "create_budget" ->
        attrs = get_in(board_approval.proposal_data, ["budget_attrs"]) || %{}

        case Cympho.Budgets.create_budget(attrs, actor, skip_governance: true) do
          {:ok, budget} ->
            GovernanceAuditLogs.log_action(
              "budget_creation_executed",
              actor,
              "Budget created via board approval: #{budget.name}",
              resource: budget,
              metadata: Map.put(meta, :budget_id, budget.id)
            )

            Phoenix.PubSub.broadcast(
              Cympho.PubSub,
              "company:#{board_approval.company_id}:governance",
              {:budget_creation_approved, board_approval.id, budget}
            )

            {:ok, budget}

          {:error, changeset} ->
            GovernanceAuditLogs.log_action(
              "budget_creation_execution_failed",
              actor,
              "Budget creation failed after board approval",
              resource: board_approval,
              metadata: Map.put(meta, :errors, traverse_errors(changeset))
            )

            {:error, changeset}
        end

      "update_budget" ->
        budget_id = get_in(board_approval.proposal_data, ["budget_id"])
        update_attrs = get_in(board_approval.proposal_data, ["update_attrs"]) || %{}

        if budget_id do
          case Cympho.Budgets.get_budget(budget_id) do
            {:ok, budget} ->
              case Cympho.Budgets.update_budget(budget, update_attrs, actor,
                     skip_governance: true
                   ) do
                {:ok, updated} ->
                  GovernanceAuditLogs.log_action(
                    "budget_increase_executed",
                    actor,
                    "Budget limit increased via board approval: #{updated.name}",
                    resource: updated,
                    metadata: Map.put(meta, :budget_id, budget_id)
                  )

                  Phoenix.PubSub.broadcast(
                    Cympho.PubSub,
                    "company:#{board_approval.company_id}:governance",
                    {:budget_increase_approved, board_approval.id, budget_id,
                     updated.limit_amount}
                  )

                  {:ok, updated}

                {:error, changeset} ->
                  GovernanceAuditLogs.log_action(
                    "budget_increase_execution_failed",
                    actor,
                    "Budget update failed after board approval",
                    resource: board_approval,
                    metadata:
                      Map.merge(meta, %{budget_id: budget_id, errors: traverse_errors(changeset)})
                  )

                  {:error, changeset}
              end

            {:error, :not_found} ->
              GovernanceAuditLogs.log_action(
                "budget_increase_execution_failed",
                nil,
                "Budget not found for approved increase",
                resource: board_approval,
                metadata: %{budget_id: budget_id}
              )

              {:error, :not_found}
          end
        else
          {:error, :missing_budget_id}
        end

      _ ->
        # Legacy: broadcast-only for backward compat
        budget_id = get_in(board_approval.proposal_data, ["budget_id"])
        new_limit = get_in(board_approval.proposal_data, ["new_limit"])

        if budget_id != nil and new_limit != nil do
          Phoenix.PubSub.broadcast(
            Cympho.PubSub,
            "company:#{board_approval.company_id}:governance",
            {:budget_increase_approved, board_approval.id, budget_id, new_limit}
          )
        end
    end
  end

  defp trigger_policy_change(board_approval) do
    action = get_in(board_approval.proposal_data, ["action"])
    meta = %{board_approval_id: board_approval.id}

    if action == "update_company" do
      company_id = get_in(board_approval.proposal_data, ["company_id"])
      update_attrs = get_in(board_approval.proposal_data, ["update_attrs"]) || %{}

      if company_id do
        case Cympho.Repo.get(Cympho.Companies.Company, company_id) do
          nil ->
            GovernanceAuditLogs.log_action(
              "policy_change_execution_failed",
              nil,
              "Company not found for approved policy change",
              resource: board_approval,
              metadata: Map.put(meta, :company_id, company_id)
            )

            {:error, :not_found}

          company ->
            case Cympho.Companies.execute_company_update(company, update_attrs) do
              {:ok, updated} ->
                GovernanceAuditLogs.log_action(
                  "policy_change_executed",
                  nil,
                  "Company config update executed after board approval",
                  resource: updated,
                  metadata: meta
                )

                Phoenix.PubSub.broadcast(
                  Cympho.PubSub,
                  "company:#{board_approval.company_id}:governance",
                  {:policy_change_approved, board_approval.id, updated}
                )

                {:ok, updated}

              {:error, changeset} ->
                GovernanceAuditLogs.log_action(
                  "policy_change_execution_failed",
                  nil,
                  "Company config update failed after board approval",
                  resource: board_approval,
                  metadata: Map.put(meta, :errors, traverse_errors(changeset))
                )

                {:error, changeset}
            end
        end
      else
        {:error, :missing_company_id}
      end
    else
      {:error, :unknown_action}
    end
  end

  defp trigger_permission_grant(board_approval) do
    principal_id = get_in(board_approval.proposal_data, ["principal_id"])
    permission = get_in(board_approval.proposal_data, ["permission"])

    if principal_id != nil and permission != nil do
      Phoenix.PubSub.broadcast(
        Cympho.PubSub,
        "company:#{board_approval.company_id}:governance",
        {:permission_grant_approved, board_approval.id, principal_id, permission}
      )
    end
  end

  defp trigger_strategic_initiative(board_approval) do
    GovernanceAuditLogs.log_action(
      "strategic_initiative_approved",
      {"board_approval", board_approval.id},
      "Strategic initiative approved: #{board_approval.title}",
      resource: board_approval,
      reasoning: board_approval.description,
      metadata: %{
        board_approval_id: board_approval.id,
        proposal_data: board_approval.proposal_data
      }
    )

    Phoenix.PubSub.broadcast(
      Cympho.PubSub,
      "company:#{board_approval.company_id}:governance",
      {:strategic_initiative_approved, board_approval.id, board_approval.proposal_data}
    )

    {:ok, board_approval}
  end

  defp traverse_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  defp stringify_keys(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
