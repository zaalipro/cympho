defmodule Cympho.IssueThreadInteractions do
  @moduledoc """
  Context for managing issue thread interactions.

  Three interaction kinds:
  - suggest_tasks — agent proposes sub-issues, user accepts/rejects each
  - ask_user_questions — agent asks structured questions, user responds
  - request_confirmation — agent asks yes/no approval
  """

  import Ecto.Query, warn: false
  require Logger

  alias Cympho.Repo
  alias Cympho.Agents.Agent
  alias Cympho.Documents
  alias Cympho.Documents.IssueDocument
  alias Cympho.Issues.Issue
  alias Cympho.Issues.IssueThreadInteraction
  alias Cympho.Issues.InteractionStateMachine
  alias Cympho.Wakes

  def list_interactions(issue_id) do
    IssueThreadInteraction
    |> where(issue_id: ^issue_id)
    |> order_by([i], asc: i.inserted_at)
    |> Repo.all()
  end

  def get_interaction!(id), do: Repo.get!(IssueThreadInteraction, id)

  def get_interaction(id) do
    case Repo.get(IssueThreadInteraction, id) do
      nil -> {:error, :not_found}
      interaction -> {:ok, interaction}
    end
  end

  def create_interaction(attrs \\ %{}) do
    result =
      Repo.transaction(fn ->
        with :ok <- validate_created_by_agent(attrs),
             {:ok, pinned_attrs} <- pin_target_revision(attrs),
             {:ok, interaction} <-
               %IssueThreadInteraction{}
               |> IssueThreadInteraction.changeset(pinned_attrs)
               |> Repo.insert() do
          interaction
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, interaction} ->
        broadcast_interaction({:interaction_created, interaction}, interaction.issue_id)

        {:ok, interaction}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def resolve_interaction(%IssueThreadInteraction{} = interaction, attrs) do
    new_status = Map.get(attrs, :status) || Map.get(attrs, "status")

    result =
      Repo.transaction(fn ->
        current =
          Repo.one(
            from i in IssueThreadInteraction,
              where: i.id == ^interaction.id,
              lock: "FOR UPDATE"
          )

        cond do
          is_nil(current) ->
            Repo.rollback(:not_found)

          not InteractionStateMachine.valid_transition?(
            current.kind,
            current.status,
            new_status
          ) ->
            Repo.rollback(:invalid_transition)

          true ->
            with :ok <- validate_target_revision(current, new_status),
                 resolved_attrs <- resolution_attrs(attrs, new_status, DateTime.utc_now()),
                 {:ok, updated} <-
                   current
                   |> IssueThreadInteraction.resolve_changeset(resolved_attrs)
                   |> Repo.update(),
                 {:ok, resumed_issue} <- maybe_resume_work_mode(updated) do
              %{interaction: updated, issue: resumed_issue}
            else
              {:error, reason} -> Repo.rollback(reason)
            end
        end
      end)

    case result do
      {:ok, %{interaction: updated, issue: resumed_issue}} ->
        maybe_create_child_issues(updated)
        maybe_post_response_comment(updated, attrs)
        maybe_broadcast_resumed_issue(resumed_issue)
        maybe_wake_creating_agent(updated)
        broadcast_interaction_updated(updated)
        {:ok, updated}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_resume_work_mode(%IssueThreadInteraction{kind: kind, status: status} = interaction)
       when kind in [:ask_user_questions, :request_confirmation] do
    issue =
      Repo.one(
        from i in Issue,
          where: i.id == ^interaction.issue_id,
          lock: "FOR UPDATE"
      )

    if issue && work_mode_wait_matches?(issue, interaction) do
      attrs = work_mode_resume_attrs(issue, kind, status)

      issue
      |> Issue.changeset(attrs)
      |> Ecto.Changeset.optimistic_lock(:lock_version)
      |> Repo.update()
    else
      if issue, do: {:ok, nil}, else: {:error, :issue_not_found}
    end
  end

  defp maybe_resume_work_mode(_interaction), do: {:ok, nil}

  defp work_mode_resume_attrs(issue, kind, status) do
    work_mode =
      case {issue.work_mode, kind, status} do
        {:ask, :ask_user_questions, :responded} -> :standard
        {:planning, :request_confirmation, :accepted} -> :standard
        _ -> issue.work_mode || :standard
      end

    attrs = %{
      work_mode: work_mode,
      monitor_state: Map.delete(issue.monitor_state || %{}, "work_mode_wait")
    }

    if issue.status == :blocked, do: Map.put(attrs, :status, :todo), else: attrs
  end

  defp work_mode_wait_matches?(%Issue{} = issue, interaction) do
    wait = Map.get(issue.monitor_state || %{}, "work_mode_wait", %{})

    Map.get(wait, "interaction_id") == interaction.id and
      Map.get(wait, "kind") == to_string(interaction.kind)
  end

  defp maybe_broadcast_resumed_issue(nil), do: :ok

  defp maybe_broadcast_resumed_issue(%Issue{} = issue) do
    Cympho.RateLimiting.dedup_pubsub(
      Cympho.PubSub,
      "company:#{issue.company_id}:issues",
      {:issue_updated, issue}
    )

    CymphoWeb.Events.broadcast_issue_update(issue, :issue_updated)
  end

  defp pin_target_revision(attrs) do
    kind = field(attrs, :kind)
    payload = field(attrs, :payload, %{})

    if kind in [:request_confirmation, "request_confirmation"] and is_map(payload) do
      pin_confirmation_target(attrs, payload)
    else
      {:ok, attrs}
    end
  end

  defp pin_confirmation_target(attrs, payload) do
    case field(payload, :target_document_id) do
      nil ->
        {:ok, attrs}

      document_id when is_binary(document_id) ->
        issue_id = field(attrs, :issue_id)

        case locked_issue_document(issue_id, document_id) do
          %IssueDocument{} = document ->
            pinned_payload =
              payload
              |> Map.put("target_document_id", document.id)
              |> Map.put("target_document_key", document.key)
              |> Map.put("target_document_title", document.title)
              |> Map.put(
                "target_revision_number",
                current_document_revision_number(document)
              )
              |> Map.put("target_revision_sha256", document_revision_sha256(document))

            {:ok, put_field(attrs, :payload, pinned_payload)}

          nil ->
            {:error, :invalid_target_document}
        end

      _document_id ->
        {:error, :invalid_target_document}
    end
  end

  defp validate_target_revision(
         %IssueThreadInteraction{
           kind: :request_confirmation,
           issue_id: issue_id,
           payload: payload
         },
         :accepted
       )
       when is_map(payload) do
    case field(payload, :target_document_id) do
      nil ->
        :ok

      document_id when is_binary(document_id) ->
        document = locked_issue_document(issue_id, document_id)

        if current_target_revision?(document, payload) do
          :ok
        else
          {:error, :stale_target_revision}
        end

      _document_id ->
        {:error, :stale_target_revision}
    end
  end

  defp validate_target_revision(_interaction, _new_status), do: :ok

  @doc false
  def target_revision_current?(%IssueThreadInteraction{
        kind: :request_confirmation,
        issue_id: issue_id,
        payload: payload
      })
      when is_map(payload) do
    case field(payload, :target_document_id) do
      nil ->
        true

      document_id when is_binary(document_id) ->
        issue_id
        |> locked_issue_document(document_id)
        |> current_target_revision?(payload)

      _document_id ->
        false
    end
  end

  def target_revision_current?(%IssueThreadInteraction{}), do: true

  defp current_target_revision?(%IssueDocument{} = document, payload) do
    field(payload, :target_revision_number) ==
      current_document_revision_number(document) and
      field(payload, :target_revision_sha256) == document_revision_sha256(document)
  end

  defp current_target_revision?(_document, _payload), do: false

  # Revisions store the snapshot that was current immediately before an edit.
  # The live document is therefore one generation ahead of the latest stored
  # historical snapshot; presenting it this way keeps the owner-facing number
  # one-based (new document = revision 1).
  defp current_document_revision_number(%IssueDocument{} = document),
    do: Documents.get_latest_revision_number(document.id) + 1

  defp locked_issue_document(issue_id, document_id)
       when is_binary(issue_id) and is_binary(document_id) do
    Repo.one(
      from d in IssueDocument,
        where: d.id == ^document_id and d.issue_id == ^issue_id,
        lock: "FOR SHARE"
    )
  end

  defp locked_issue_document(_issue_id, _document_id), do: nil

  defp document_revision_sha256(%IssueDocument{} = document) do
    :sha256
    |> :crypto.hash(
      Enum.join(
        [document.id, document.key, document.title, document.format, document.body],
        <<0>>
      )
    )
    |> Base.encode16(case: :lower)
  end

  defp field(map, key, default \\ nil)

  defp field(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, to_string(key), default))

  defp field(_map, _key, default), do: default

  defp put_field(map, key, value) when is_map(map) do
    if Map.has_key?(map, key) do
      Map.put(map, key, value)
    else
      Map.put(map, to_string(key), value)
    end
  end

  defp resolution_attrs(attrs, new_status, resolved_at) do
    %{
      status: new_status,
      resolved_by_user_id: field(attrs, :resolved_by_user_id),
      resolved_at: resolved_at
    }
  end

  defp validate_created_by_agent(attrs) do
    case field(attrs, :created_by_agent_id) do
      nil ->
        :ok

      agent_id when is_binary(agent_id) ->
        if created_by_agent_matches_issue?(field(attrs, :issue_id), agent_id) do
          :ok
        else
          {:error, :invalid_created_by_agent}
        end

      _agent_id ->
        {:error, :invalid_created_by_agent}
    end
  end

  defp created_by_agent_matches_issue?(issue_id, agent_id)
       when is_binary(issue_id) and is_binary(agent_id) do
    Repo.exists?(
      from issue in Issue,
        join: agent in Agent,
        on: agent.id == ^agent_id,
        where:
          issue.id == ^issue_id and
            (agent.company_id == issue.company_id or
               (is_nil(agent.company_id) and is_nil(issue.company_id)))
    )
  end

  defp created_by_agent_matches_issue?(_issue_id, _agent_id), do: false

  # suggest_tasks: accepted -> create child issues for each accepted task
  defp maybe_create_child_issues(%IssueThreadInteraction{
         kind: :suggest_tasks,
         status: :accepted,
         issue_id: issue_id,
         payload: %{"tasks" => tasks}
       }) do
    company_id = issue_company_id(issue_id)

    Enum.each(tasks, fn task ->
      if Map.get(task, "accepted", false) do
        Cympho.Issues.create_issue(%{
          title: Map.get(task, "title", "Untitled task"),
          description: Map.get(task, "description"),
          parent_id: Map.get(task, "parent_issue_id"),
          project_id: Map.get(task, "project_id"),
          company_id: company_id
        })
      end
    end)
  end

  defp maybe_create_child_issues(_), do: :ok

  # ask_user_questions: responded -> store response as a comment
  defp maybe_post_response_comment(
         %IssueThreadInteraction{
           kind: :ask_user_questions,
           issue_id: issue_id,
           resolved_by_user_id: user_id
         },
         attrs
       ) do
    case field(attrs, :response) do
      response when is_binary(response) ->
        Cympho.Comments.create_comment(%{
          body: response,
          author_type: "user",
          author_id: to_string(user_id),
          issue_id: issue_id
        })

      _response ->
        :ok
    end
  end

  defp maybe_post_response_comment(_, _), do: :ok

  # Wake the creating agent on resolution
  defp maybe_wake_creating_agent(%IssueThreadInteraction{
         created_by_agent_id: nil
       }),
       do: :ok

  defp maybe_wake_creating_agent(%IssueThreadInteraction{
         created_by_agent_id: agent_id,
         issue_id: issue_id,
         kind: kind,
         status: status
       }) do
    if created_by_agent_matches_issue?(issue_id, agent_id) do
      Wakes.do_wake_agent(
        agent_id,
        issue_id,
        "interaction_#{kind}_#{status}",
        "system",
        nil,
        %{
          source: "issue_interaction",
          interaction_kind: to_string(kind),
          resolution: to_string(status)
        }
      )
    else
      Logger.warning("skipping interaction wake for an agent outside the issue company",
        issue_id: issue_id,
        agent_id: agent_id,
        interaction_kind: kind,
        resolution: status
      )

      :ok
    end
  end

  defp broadcast_interaction_updated(interaction) do
    broadcast_interaction({:interaction_updated, interaction}, interaction.issue_id)
  end

  # Interaction events are issue-scoped; broadcast on the issue's
  # company-scoped topic (consumed by IssueLive.Show) rather than the bare
  # "issues" topic, which would leak across tenants.
  defp broadcast_interaction(message, issue_id) do
    case issue_company_id(issue_id) do
      nil ->
        {:error, :no_company}

      company_id ->
        result = Cympho.PubSubGuard.broadcast("company:#{company_id}:issues", message)
        Cympho.OwnerAttention.notify_changed(company_id)
        result
    end
  end

  defp issue_company_id(issue_id) when is_binary(issue_id) do
    Repo.one(from i in Issue, where: i.id == ^issue_id, select: i.company_id)
  end

  defp issue_company_id(_), do: nil

  def pending_interactions(issue_id) do
    IssueThreadInteraction
    |> where(issue_id: ^issue_id)
    |> where(status: :pending)
    |> Repo.all()
  end
end
