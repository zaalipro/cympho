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
    case %IssueThreadInteraction{}
         |> IssueThreadInteraction.changeset(attrs)
         |> Repo.insert() do
      {:ok, interaction} ->
        broadcast_interaction({:interaction_created, interaction}, interaction.issue_id)

        {:ok, interaction}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def resolve_interaction(%IssueThreadInteraction{} = interaction, attrs) do
    new_status = Map.get(attrs, :status) || Map.get(attrs, "status")

    if InteractionStateMachine.valid_transition?(interaction.kind, interaction.status, new_status) do
      attrs = Map.put(attrs, :resolved_at, DateTime.utc_now())

      case interaction
           |> IssueThreadInteraction.resolve_changeset(attrs)
           |> Repo.update() do
        {:ok, updated} ->
          maybe_create_child_issues(updated)
          maybe_post_response_comment(updated, attrs)
          maybe_wake_creating_agent(updated)
          broadcast_interaction_updated(updated)
          {:ok, updated}

        {:error, changeset} ->
          {:error, changeset}
      end
    else
      {:error, :invalid_transition}
    end
  end

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
         %{"response" => response}
       )
       when is_binary(response) do
    Cympho.Comments.create_comment(%{
      body: response,
      author_type: "user",
      author_id: to_string(user_id),
      issue_id: issue_id
    })
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
    Wakes.do_wake_agent(
      agent_id,
      issue_id,
      "interaction_#{kind}_#{status}",
      "system",
      nil,
      %{interaction_kind: to_string(kind), resolution: to_string(status)}
    )
  end

  defp broadcast_interaction_updated(interaction) do
    broadcast_interaction({:interaction_updated, interaction}, interaction.issue_id)
  end

  # Interaction events are issue-scoped; broadcast on the issue's
  # company-scoped topic (consumed by IssueLive.Show) rather than the bare
  # "issues" topic, which would leak across tenants.
  defp broadcast_interaction(message, issue_id) do
    case issue_company_id(issue_id) do
      nil -> {:error, :no_company}
      company_id -> Cympho.PubSubGuard.broadcast("company:#{company_id}:issues", message)
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
