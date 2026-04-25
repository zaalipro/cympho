defmodule CymphoWeb.IssueInteractionJSON do
  alias Cympho.Issues.IssueThreadInteraction

  def interaction_data(%IssueThreadInteraction{} = interaction) do
    %{
      id: interaction.id,
      issue_id: interaction.issue_id,
      kind: interaction.kind,
      payload: interaction.payload,
      status: interaction.status,
      created_by_agent_id: interaction.created_by_agent_id,
      resolved_by_user_id: interaction.resolved_by_user_id,
      resolved_at: interaction.resolved_at,
      inserted_at: interaction.inserted_at,
      updated_at: interaction.updated_at
    }
  end
end
