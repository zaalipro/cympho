defmodule CymphoWeb.GoalLiveTest do
  use CymphoWeb.LiveCase, async: true

  alias Cympho.Goals
  alias Cympho.Issues
  alias Cympho.Projects

  describe "Goals index" do
    test "renders alignment health, floating risk work, and per-goal work health", %{
      conn: conn,
      current_company: company
    } do
      {:ok, project} =
        Projects.create_project(%{
          name: "Goal Page Project",
          prefix: "GPP",
          company_id: company.id
        })

      {:ok, mission} =
        Goals.create_goal(%{
          title: "Goal page mission",
          description: "Keep autonomous work attached to strategy.",
          company_id: company.id,
          project_id: project.id,
          goal_type: :mission,
          priority: "high"
        })

      for status <- [:todo, :in_review, :blocked, :done] do
        {:ok, _issue} =
          Issues.create_issue(%{
            title: "Goal page #{status}",
            company_id: company.id,
            project_id: project.id,
            goal_id: mission.id,
            status: status
          })
      end

      {:ok, _floating} =
        Issues.create_issue(%{
          title: "Goal page floating issue",
          company_id: company.id,
          status: :todo,
          priority: :critical
        })

      {:ok, _view, html} = live(conn, "/goals")

      assert html =~ "Mission alignment"
      assert html =~ "75% of open work is goal-linked"
      assert html =~ "Highest-risk floating work"
      assert html =~ "Goal page floating issue"
      assert html =~ "Goal page mission"
      assert html =~ "1/4 linked issues"
      assert html =~ "25% complete"
    end
  end
end
