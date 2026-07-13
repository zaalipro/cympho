defmodule CymphoWeb.AgentEditLiveTest do
  use CymphoWeb.LiveCase, async: true

  alias Cympho.Agents

  # AgentLive.Edit is a legacy route that redirects to the show page's
  # Configuration tab. It lives in the board-governed live session, so mounting
  # it requires a board-member connection to clear the BoardAuth on_mount hook.
  defp board_conn do
    conn = authenticated_conn(%{is_board_member: true})
    {conn, current_company()}
  end

  describe "AgentLive.Edit" do
    test "redirects to the show page configuration tab" do
      {conn, company} = board_conn()

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Editable Agent",
          role: :engineer,
          status: :idle,
          adapter: :process,
          company_id: company.id
        })

      assert {:error, {:live_redirect, %{to: to}}} = live(conn, "/agents/#{agent.id}/edit")
      assert to == "/agents/#{agent.id}?tab=configuration"
    end
  end
end
