defmodule CymphoWeb.GoalLiveTest do
  use CymphoWeb.LiveCase, async: true

  alias Cympho.Goals
  alias Cympho.Issues
  alias Cympho.Projects

  defp create_project(attrs) do
    unique = System.unique_integer([:positive])

    attrs
    |> Map.put_new(:company_id, current_company_id())
    |> Map.put_new(:prefix, "G#{alpha_suffix(unique)}")
    |> Projects.create_project()
  end

  defp create_goal(attrs) do
    attrs
    |> Map.put_new(:company_id, current_company_id())
    |> Goals.create_goal()
  end

  defp alpha_suffix(number), do: alpha_suffix(number, "")

  defp alpha_suffix(0, ""), do: "A"
  defp alpha_suffix(0, acc), do: String.slice(acc, 0, 9)

  defp alpha_suffix(number, acc) do
    alpha_suffix(div(number, 26), <<?A + rem(number, 26)>> <> acc)
  end

  describe "Goals index" do
    test "defaults to compact density", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/goals")

      assert html =~ "Goals"
      assert html =~ "Compact"
      assert html =~ "Detailed"
      assert html =~ "Goal command"
      refute html =~ "Mission alignment"
    end

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

      {:ok, floating} =
        Issues.create_issue(%{
          title: "Goal page floating issue",
          company_id: company.id,
          status: :todo,
          priority: :critical
        })

      {:ok, view, html} = live(conn, "/goals?density=detailed")

      assert html =~ "Goal command"
      assert html =~ "Link floating work to strategy"
      assert html =~ "Open unlinked issue"
      assert html =~ "Attach"
      assert html =~ "Needs link"
      assert html =~ "Blocked goals"
      assert html =~ "Mission alignment"
      assert html =~ "75% of open work is goal-linked"
      assert html =~ "Highest-risk floating work"
      assert html =~ "Goal page floating issue"
      assert html =~ "Goal page mission"
      assert html =~ "1/4 linked issues"
      assert html =~ "25% complete"

      html =
        view
        |> element("form[phx-submit='link_issue_to_goal']")
        |> render_submit(%{"issue_id" => floating.id, "goal_id" => mission.id})

      assert html =~ "100% of open work is goal-linked"
      assert html =~ "No open unlinked issues in this company."
      assert html =~ "1/5 linked issues"
      assert html =~ "20% complete"

      {:ok, linked_issue} = Issues.get_issue(floating.id)
      assert linked_issue.goal_id == mission.id
      assert linked_issue.project_id == project.id
    end
  end

  describe "Goals new" do
    test "renders the alignment planning form", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/goals/new")

      assert html =~ "Goal alignment plan"
      assert html =~ "Strategy hierarchy"
      assert html =~ "Outcome brief"
      assert html =~ "Goal type"
      assert html =~ "Parent goal"
      assert html =~ "Project context"
      assert html =~ "Setup checklist"
      assert html =~ "Root goals become missions"
    end

    test "renders current-company project and parent choices", %{conn: conn} do
      {:ok, project} = create_project(%{name: "Growth Platform"})

      {:ok, _mission} =
        create_goal(%{
          title: "Win launch market",
          goal_type: :mission,
          project_id: project.id
        })

      {:ok, _view, html} = live(conn, "/goals/new")

      assert html =~ "Growth Platform"
      assert html =~ "Mission · Win launch market"
      assert html =~ "No parent goal"
      assert html =~ "No project context"
    end

    test "creates child goal and inherits parent project when project is blank", %{conn: conn} do
      {:ok, project} = create_project(%{name: "Autonomy Platform"})

      {:ok, mission} =
        create_goal(%{
          title: "Make autonomy useful",
          goal_type: :mission,
          project_id: project.id
        })

      {:ok, view, _html} = live(conn, "/goals/new")

      result =
        view
        |> form("form[phx-submit=save]",
          goal: %{
            title: "Reduce handoff drift",
            description: "Every handoff has owner-visible acceptance evidence.",
            goal_type: "initiative",
            parent_id: mission.id,
            project_id: "",
            status: "active",
            priority: "high"
          }
        )
        |> render_submit()

      assert {:error, {:live_redirect, %{to: "/goals"}}} = result

      goal =
        current_company_id()
        |> Goals.list_goals_by_company()
        |> Enum.find(&(&1.title == "Reduce handoff drift"))

      assert goal.goal_type == :initiative
      assert goal.parent_id == mission.id
      assert goal.project_id == project.id
      assert goal.priority == "high"
    end
  end

  describe "Goals edit" do
    test "renders hierarchy and project controls", %{conn: conn} do
      {:ok, goal} = create_goal(%{title: "Editable mission", goal_type: :mission})

      {:ok, _view, html} = live(conn, "/goals/#{goal.id}/edit")

      assert html =~ "Goal alignment plan"
      assert html =~ "Maintain the strategic target"
      assert html =~ "Goal type"
      assert html =~ "Parent goal"
      assert html =~ "Project context"
      assert html =~ "Maintenance checklist"
    end

    test "updates hierarchy and project context", %{conn: conn} do
      {:ok, project} = create_project(%{name: "Delivery Platform"})

      {:ok, parent} =
        create_goal(%{
          title: "Delivery mission",
          goal_type: :mission,
          project_id: project.id
        })

      {:ok, goal} = create_goal(%{title: "Unplaced work", goal_type: :mission})

      {:ok, view, _html} = live(conn, "/goals/#{goal.id}/edit")

      result =
        view
        |> form("form[phx-submit=save]",
          goal: %{
            title: "Placed milestone",
            goal_type: "milestone",
            parent_id: parent.id,
            project_id: "",
            status: "active",
            priority: "critical"
          }
        )
        |> render_submit()

      assert {:error, {:live_redirect, %{to: redirect_path}}} = result
      assert redirect_path == "/goals/#{goal.id}"

      updated = Goals.get_goal!(goal.id)
      assert updated.title == "Placed milestone"
      assert updated.goal_type == :milestone
      assert updated.parent_id == parent.id
      assert updated.project_id == project.id
      assert updated.priority == "critical"
    end
  end
end
