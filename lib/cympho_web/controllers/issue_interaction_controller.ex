defmodule CymphoWeb.IssueInteractionController do
  use CymphoWeb, :controller

  alias Cympho.IssueThreadInteractions

  action_fallback CymphoWeb.FallbackController

  def index(conn, %{"issue_id" => issue_id}) do
    interactions = IssueThreadInteractions.list_interactions(issue_id)

    json(conn, %{data: Enum.map(interactions, &CymphoWeb.IssueInteractionJSON.interaction_data/1)})
  end

  def create(conn, %{"issue_id" => issue_id} = params) do
    attrs =
      params
      |> Map.put("issue_id", issue_id)

    with {:ok, interaction} <- IssueThreadInteractions.create_interaction(attrs) do
      conn
      |> put_status(:created)
      |> json(%{data: CymphoWeb.IssueInteractionJSON.interaction_data(interaction)})
    end
  end

  def show(conn, %{"issue_id" => _issue_id, "id" => id}) do
    with {:ok, interaction} <- IssueThreadInteractions.get_interaction(id) do
      json(conn, %{data: CymphoWeb.IssueInteractionJSON.interaction_data(interaction)})
    end
  end

  def resolve(conn, %{
        "issue_id" => _issue_id,
        "id" => id,
        "status" => status,
        "resolved_by_user_id" => user_id
      }) do
    with {:ok, interaction} <- IssueThreadInteractions.get_interaction(id),
         attrs <- build_resolve_attrs(status, user_id, conn.params),
         {:ok, updated} <- IssueThreadInteractions.resolve_interaction(interaction, attrs) do
      json(conn, %{data: CymphoWeb.IssueInteractionJSON.interaction_data(updated)})
    end
  end

  defp build_resolve_attrs(status, user_id, params) do
    base = %{
      "status" => String.to_existing_atom(status),
      "resolved_by_user_id" => user_id
    }

    if response = Map.get(params, "response") do
      Map.put(base, "response", response)
    else
      base
    end
  end
end
