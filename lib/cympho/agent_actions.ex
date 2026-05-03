defmodule Cympho.AgentActions do
  @moduledoc """
  Parses and executes the `cympho-actions` contract emitted by runtime agents.

  Agents are allowed to request business side effects only through this JSON
  block. Execution is company-scoped and audited through the normal contexts.
  """

  import Ecto.Query, warn: false

  alias Cympho.{Activities, Agents, Comments, Issues, Repo}
  alias Cympho.Agents.Agent
  alias Cympho.Issues.Issue

  @max_actions 10
  @supported_types ~w(
    create_issue
    submit_review
    approve_issue
    request_changes
    block_issue
    comment
  )
  @roles ~w(ceo cto engineer)
  @priorities ~w(low medium high critical)

  @type action :: map()

  @doc """
  Parses exactly one fenced `cympho-actions` JSON block from an agent response.
  """
  @spec parse(String.t()) :: {:ok, [action()]} | {:error, atom() | tuple()}
  def parse(text) when is_binary(text) do
    case Regex.scan(~r/```cympho-actions\s*\n(.*?)```/s, text, capture: :all_but_first) do
      [] ->
        {:error, :missing_action_block}

      [_one, _two | _] ->
        {:error, :multiple_action_blocks}

      [[json]] ->
        json
        |> Jason.decode()
        |> case do
          {:ok, decoded} -> validate_payload(decoded)
          {:error, error} -> {:error, {:invalid_json, Exception.message(error)}}
        end
    end
  end

  def parse(_), do: {:error, :missing_action_block}

  @doc """
  Executes validated actions for an issue and agent.
  """
  @spec execute(Issue.t(), Agent.t() | binary(), [action()]) ::
          {:ok, %{issue: Issue.t(), results: [map()]}} | {:error, term()}
  def execute(%Issue{} = issue, %Agent{} = agent, actions) when is_list(actions) do
    Repo.transaction(fn ->
      current_issue = Issues.get_issue!(issue.id)

      results =
        Enum.map(actions, fn action ->
          case execute_action(current_issue, agent, action) do
            {:ok, result} ->
              log_action(current_issue, agent, action, result)
              result

            {:error, reason} ->
              Repo.rollback(reason)
          end
        end)

      %{issue: Issues.get_issue!(issue.id), results: results}
    end)
    |> case do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  def execute(%Issue{} = issue, agent_id, actions) when is_binary(agent_id) do
    with {:ok, agent} <- Agents.get_agent(agent_id) do
      execute(issue, agent, actions)
    end
  end

  def execute(_issue, _agent, _actions), do: {:error, :invalid_execution_context}

  def unresolved_current_issue?(%Issue{} = issue, %Agent{} = agent) do
    case Repo.get(Issue, issue.id) do
      %Issue{status: :in_progress, assignee_id: agent_id} when agent_id == agent.id -> true
      _ -> false
    end
  end

  def unresolved_current_issue?(%Issue{} = issue, agent_id) when is_binary(agent_id) do
    case Agents.get_agent(agent_id) do
      {:ok, agent} -> unresolved_current_issue?(issue, agent)
      {:error, _} -> false
    end
  end

  def unresolved_current_issue?(_issue, _agent), do: false

  defp validate_payload(%{"actions" => actions}) when is_list(actions) do
    cond do
      actions == [] ->
        {:error, :empty_actions}

      length(actions) > @max_actions ->
        {:error, {:too_many_actions, @max_actions}}

      true ->
        actions
        |> Enum.map(&validate_action/1)
        |> collect_validated()
    end
  end

  defp validate_payload(_), do: {:error, :missing_actions}

  defp validate_action(%{} = action) do
    action = normalize_string_keys(action)

    case action["type"] do
      type when type in @supported_types ->
        validate_supported_action(type, action)

      nil ->
        {:error, :invalid_action}

      type ->
        {:error, {:unsupported_action, type}}
    end
  end

  defp validate_action(_), do: {:error, :invalid_action}

  defp validate_supported_action(type, action) do
    case type do
      "create_issue" ->
        with :ok <- require_string(action, "title"),
             :ok <- validate_role(action["role"]),
             :ok <- validate_priority(Map.get(action, "priority", "medium")) do
          {:ok,
           Map.merge(action, %{
             "description" => Map.get(action, "description", ""),
             "priority" => Map.get(action, "priority", "medium")
           })}
        end

      "submit_review" ->
        with :ok <- validate_role(action["role"]) do
          {:ok, action}
        end

      "approve_issue" ->
        {:ok, action}

      "request_changes" ->
        with :ok <- validate_role(action["role"]) do
          {:ok, action}
        end

      "block_issue" ->
        {:ok, action}

      "comment" ->
        with :ok <- require_string(action, "body") do
          {:ok, action}
        end
    end
  end

  defp collect_validated(results) do
    Enum.reduce_while(results, {:ok, []}, fn
      {:ok, action}, {:ok, acc} -> {:cont, {:ok, [action | acc]}}
      {:error, reason}, _ -> {:halt, {:error, reason}}
    end)
    |> case do
      {:ok, actions} -> {:ok, Enum.reverse(actions)}
      error -> error
    end
  end

  defp execute_action(issue, agent, %{"type" => "create_issue"} = action) do
    attrs = %{
      title: action["title"],
      description: action["description"] || "",
      priority: action["priority"] || "medium",
      status: :todo,
      company_id: issue.company_id,
      project_id: issue.project_id,
      goal_id: issue.goal_id,
      parent_id: issue.id,
      assigned_role: action["role"],
      created_by_agent_id: agent.id,
      origin_type: "agent_action",
      origin_id: issue.id,
      request_depth: (issue.request_depth || 0) + 1,
      actor_type: "agent",
      actor_id: agent.id
    }

    case Issues.create_issue(attrs) do
      {:ok, created} -> {:ok, %{type: "create_issue", issue_id: created.id}}
      error -> error
    end
  end

  defp execute_action(issue, agent, %{"type" => "submit_review"} = action) do
    update_workflow_issue(issue, agent, %{
      status: :in_review,
      assignee_id: nil,
      checkout_run_id: nil,
      checked_out_at: nil,
      assigned_role: action["role"]
    })
    |> with_optional_agent_comment(issue, agent, action["notes"], "Submitted for review")
    |> result_for("submit_review")
  end

  defp execute_action(issue, agent, %{"type" => "approve_issue"} = action) do
    with {:ok, transitioned} <- Issues.transition_issue(issue, :done),
         {:ok, released} <- Issues.force_release_issue(transitioned, :done),
         {:ok, _} <- maybe_agent_comment(issue, agent, action["notes"]) do
      {:ok, %{type: "approve_issue", issue_id: released.id}}
    end
  end

  defp execute_action(issue, agent, %{"type" => "request_changes"} = action) do
    reason = action["reason"] || "Changes requested."

    with {:ok, updated} <-
           update_workflow_issue(issue, agent, %{
             status: :todo,
             assignee_id: nil,
             checkout_run_id: nil,
             checked_out_at: nil,
             assigned_role: action["role"]
           }),
         {:ok, _comment} <- maybe_agent_comment(issue, agent, reason) do
      {:ok, %{type: "request_changes", issue_id: updated.id}}
    end
  end

  defp execute_action(issue, agent, %{"type" => "block_issue"} = action) do
    reason = action["reason"] || "Agent blocked this issue."

    with {:ok, updated} <-
           update_workflow_issue(issue, agent, %{
             status: :blocked,
             assignee_id: nil,
             checkout_run_id: nil,
             checked_out_at: nil
           }),
         {:ok, _comment} <- system_comment(issue, reason) do
      {:ok, %{type: "block_issue", issue_id: updated.id}}
    end
  end

  defp execute_action(issue, agent, %{"type" => "comment"} = action) do
    with {:ok, comment} <- maybe_agent_comment(issue, agent, action["body"]) do
      {:ok, %{type: "comment", comment_id: comment.id}}
    end
  end

  defp update_workflow_issue(issue, agent, attrs) do
    attrs =
      attrs
      |> Map.put(:actor_type, "agent")
      |> Map.put(:actor_id, agent.id)

    Issues.update_issue(issue, attrs)
  end

  defp with_optional_agent_comment({:error, _} = error, _issue, _agent, _body, _fallback),
    do: error

  defp with_optional_agent_comment({:ok, updated}, issue, agent, body, fallback) do
    case maybe_agent_comment(issue, agent, body || fallback) do
      {:ok, _comment} -> {:ok, updated}
      error -> error
    end
  end

  defp result_for({:ok, issue}, type), do: {:ok, %{type: type, issue_id: issue.id}}
  defp result_for({:error, _} = error, _type), do: error

  defp maybe_agent_comment(_issue, _agent, nil), do: {:ok, %{id: nil}}
  defp maybe_agent_comment(_issue, _agent, ""), do: {:ok, %{id: nil}}

  defp maybe_agent_comment(issue, agent, body) do
    Comments.create_comment(%{
      body: body,
      author_type: "agent",
      author_id: agent.id,
      issue_id: issue.id
    })
  end

  defp system_comment(issue, body) do
    Comments.create_comment(%{
      body: body,
      author_type: "system",
      author_id: "00000000-0000-0000-0000-000000000000",
      issue_id: issue.id
    })
  end

  defp log_action(issue, agent, action, result) do
    Activities.log_activity(%{
      issue_id: issue.id,
      company_id: issue.company_id,
      actor_type: "agent",
      actor_id: agent.id,
      action: "agent_action",
      metadata: %{
        action_type: action["type"],
        result: result
      }
    })
  end

  defp require_string(action, field) do
    case Map.get(action, field) do
      value when is_binary(value) ->
        if String.trim(value) == "", do: {:error, {:required, field}}, else: :ok

      _ ->
        {:error, {:required, field}}
    end
  end

  defp validate_role(role) when role in @roles, do: :ok
  defp validate_role(_role), do: {:error, {:invalid_role, @roles}}

  defp validate_priority(priority) when priority in @priorities, do: :ok
  defp validate_priority(_priority), do: {:error, {:invalid_priority, @priorities}}

  defp normalize_string_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end
end
