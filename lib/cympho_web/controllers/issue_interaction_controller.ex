defmodule CymphoWeb.IssueInteractionController do
  use CymphoWeb, :controller

  alias Cympho.{IssueThreadInteractions, Issues}

  action_fallback CymphoWeb.FallbackController

  def index(conn, %{"issue_id" => issue_id}) do
    with {:ok, issue} <- scoped_issue(conn, issue_id) do
      interactions = IssueThreadInteractions.list_interactions(issue.id)

      json(conn, %{
        data: Enum.map(interactions, &CymphoWeb.IssueInteractionJSON.interaction_data/1)
      })
    end
  end

  def create(conn, %{"issue_id" => issue_id} = params) do
    with {:ok, issue} <- scoped_issue(conn, issue_id) do
      attrs = Map.put(params, "issue_id", issue.id)

      with {:ok, interaction} <- IssueThreadInteractions.create_interaction(attrs) do
        conn
        |> put_status(:created)
        |> json(%{data: CymphoWeb.IssueInteractionJSON.interaction_data(interaction)})
      end
    end
  end

  def show(conn, %{"issue_id" => issue_id, "id" => id}) do
    with {:ok, _issue} <- scoped_issue(conn, issue_id),
         {:ok, interaction} <- IssueThreadInteractions.get_interaction(id),
         :ok <- enforce_issue_match(interaction, issue_id) do
      json(conn, %{data: CymphoWeb.IssueInteractionJSON.interaction_data(interaction)})
    end
  end

  def resolve(conn, %{"issue_id" => issue_id, "id" => id, "status" => status} = params) do
    user_id = conn.assigns.current_user.id

    with {:ok, _issue} <- scoped_issue(conn, issue_id),
         {:ok, status_atom} <- parse_interaction_status(status),
         {:ok, interaction} <- IssueThreadInteractions.get_interaction(id),
         :ok <- enforce_issue_match(interaction, issue_id),
         attrs <- build_resolve_attrs(status_atom, user_id, params),
         {:ok, updated} <- IssueThreadInteractions.resolve_interaction(interaction, attrs) do
      json(conn, %{data: CymphoWeb.IssueInteractionJSON.interaction_data(updated)})
    end
  end

  # Map the user-supplied status string through an explicit whitelist instead
  # of String.to_existing_atom/1, which raises on unknown input.
  @interaction_statuses %{
    "pending" => :pending,
    "accepted" => :accepted,
    "rejected" => :rejected,
    "responded" => :responded
  }

  defp parse_interaction_status(status) do
    case Map.fetch(@interaction_statuses, status) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, :invalid_status}
    end
  end

  defp scoped_issue(conn, issue_id) do
    Issues.get_company_issue(conn.assigns.current_company.id, issue_id)
  end

  defp enforce_issue_match(interaction, issue_id) do
    if interaction.issue_id == issue_id, do: :ok, else: {:error, :not_found}
  end

  defp build_resolve_attrs(status_atom, user_id, params) do
    base = %{
      "status" => status_atom,
      "resolved_by_user_id" => user_id
    }

    if response = Map.get(params, "response") do
      Map.put(base, "response", response)
    else
      base
    end
  end
end
