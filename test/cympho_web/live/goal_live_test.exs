defmodule CymphoWeb.GoalLiveTest do
  use CymphoWeb.LiveCase, async: true

  import Ecto.Query

  alias Cympho.Goals
  alias Cympho.Issues
  alias Cympho.Issues.Issue
  alias Cympho.Projects
  alias Cympho.Repo

  defp create_foreign_company do
    unique = System.unique_integer([:positive])

    {:ok, company} =
      Cympho.Companies.create_company(%{
        name: "Foreign Goal Live Co #{unique}",
        slug: "foreign-goal-live-#{unique}"
      })

    company
  end

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

  describe "Goals show" do
    test "renders progress glance and linked work grouping", %{
      conn: conn,
      current_company: company
    } do
      {:ok, goal} =
        Goals.create_goal(%{
          title: "Show page mission",
          company_id: company.id,
          goal_type: :mission
        })

      for status <- [:todo, :done] do
        {:ok, _issue} =
          Issues.create_issue(%{
            title: "Show page #{status}",
            company_id: company.id,
            goal_id: goal.id,
            status: status
          })
      end

      {:ok, _view, html} = live(conn, "/goals/#{goal.id}")

      assert html =~ "Linked work"
      assert html =~ "% complete"
      assert html =~ "Moved this week"
      assert html =~ "Show page todo"
      assert html =~ "2 shown"
    end

    test "shows a reassuring empty state when nothing is linked", %{
      conn: conn,
      current_company: company
    } do
      {:ok, goal} =
        Goals.create_goal(%{
          title: "Empty show mission",
          company_id: company.id,
          goal_type: :mission
        })

      {:ok, _view, html} = live(conn, "/goals/#{goal.id}")

      assert html =~ "No issues linked yet"
      assert html =~ "Nothing linked yet"
    end

    test "does not expose a legacy cross-company issue linked to the goal", %{
      conn: conn,
      current_company: company
    } do
      foreign_company = create_foreign_company()

      {:ok, goal} =
        Goals.create_goal(%{
          title: "Scoped show mission",
          company_id: company.id,
          goal_type: :mission
        })

      {:ok, foreign_issue} =
        Issues.create_issue(%{
          title: "Foreign linked issue must stay hidden",
          company_id: foreign_company.id,
          status: :done
        })

      # Simulate a historical row written before association-scope validation.
      Repo.update_all(from(i in Issue, where: i.id == ^foreign_issue.id), set: [goal_id: goal.id])

      {:ok, _view, html} = live(conn, "/goals/#{goal.id}")

      refute html =~ foreign_issue.title
      assert html =~ "No issues linked yet"
      assert html =~ "Nothing linked yet"
    end
  end

  describe "Goals new" do
    test "renders the alignment planning form", %{conn: conn} do
      {:ok, view, html} = live(conn, "/goals/new")

      # The section eyebrows restated the fields under them and each carried a
      # help paragraph; the help is now a ? marker's title/aria-label.
      refute html =~ "Goal alignment plan"
      refute html =~ "Strategy hierarchy"
      refute html =~ "Outcome brief"
      assert html =~ "Anchor work to an outcome"
      assert html =~ "Write this like the owner-visible result agents should optimize for."
      assert html =~ "Missions sit at the top."
      assert html =~ "Goal type"
      assert html =~ "Parent goal"
      assert html =~ "Project context"
      assert html =~ "Setup checklist"
      assert html =~ "Root goals become missions"
      # The aside was the only panel on this page with no mode gate at all.
      assert has_element?(view, "aside.ui-advanced-only [data-testid='goal-setup-checklist']")
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

    test "stamps the current company and rejects forged project and parent ids", %{
      conn: conn,
      current_company: company
    } do
      {:ok, project} = create_project(%{name: "Current Goal Project"})
      foreign_company = create_foreign_company()
      unique = System.unique_integer([:positive])

      {:ok, foreign_project} =
        Projects.create_project(%{
          name: "Foreign Goal Project #{unique}",
          prefix: "F#{alpha_suffix(unique)}",
          company_id: foreign_company.id
        })

      {:ok, foreign_parent} =
        Goals.create_goal(%{
          title: "Foreign Goal Parent #{unique}",
          company_id: foreign_company.id,
          project_id: foreign_project.id
        })

      {:ok, view, _html} = live(conn, "/goals/new")

      result =
        render_submit(view, "save", %{
          "goal" => %{
            "title" => "Stamped Live Goal #{unique}",
            "company_id" => foreign_company.id,
            "project_id" => project.id
          }
        })

      assert {:error, {:live_redirect, %{to: "/goals"}}} = result

      stamped =
        company.id
        |> Goals.list_goals_by_company()
        |> Enum.find(&(&1.title == "Stamped Live Goal #{unique}"))

      assert stamped.company_id == company.id
      assert stamped.project_id == project.id

      {:ok, view, _html} = live(conn, "/goals/new")

      render_submit(view, "save", %{
        "goal" => %{
          "title" => "Forged Project Goal #{unique}",
          "project_id" => foreign_project.id
        }
      })

      flash = :sys.get_state(view.pid).socket.assigns.flash

      assert Phoenix.Flash.get(flash, :error) ==
               "Choose a project and parent goal from this company."

      refute Enum.any?(
               Goals.list_goals_by_company(company.id),
               &(&1.title == "Forged Project Goal #{unique}")
             )

      render_submit(view, "save", %{
        "goal" => %{
          "title" => "Forged Parent Goal #{unique}",
          "parent_id" => foreign_parent.id
        }
      })

      flash = :sys.get_state(view.pid).socket.assigns.flash

      assert Phoenix.Flash.get(flash, :error) ==
               "Choose a project and parent goal from this company."

      refute Enum.any?(
               Goals.list_goals_by_company(company.id),
               &(&1.title == "Forged Parent Goal #{unique}")
             )
    end
  end

  describe "Goals edit" do
    test "renders hierarchy and project controls", %{conn: conn} do
      {:ok, goal} = create_goal(%{title: "Editable mission", goal_type: :mission})

      {:ok, _view, html} = live(conn, "/goals/#{goal.id}/edit")

      refute html =~ "Goal alignment plan"
      assert html =~ "Maintain the strategic target"
      assert html =~ "Move this goal carefully."
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

    test "rejects an A to B to A cycle and ignores forged company_id", %{
      conn: conn,
      current_company: company
    } do
      {:ok, project} = create_project(%{name: "Cycle Project"})
      foreign_company = create_foreign_company()

      {:ok, a} =
        create_goal(%{
          title: "Live Cycle A",
          goal_type: :mission,
          project_id: project.id
        })

      {:ok, b} =
        create_goal(%{
          title: "Live Cycle B",
          goal_type: :initiative,
          project_id: project.id,
          parent_id: a.id
        })

      {:ok, view, _html} = live(conn, "/goals/#{a.id}/edit")

      html =
        render_submit(view, "save", %{
          "goal" => %{
            "title" => "Live Cycle A renamed",
            "company_id" => foreign_company.id,
            "parent_id" => b.id,
            "project_id" => project.id
          }
        })

      assert html =~ "would create a cycle"

      unchanged = Goals.get_goal!(a.id)
      assert unchanged.title == "Live Cycle A"
      assert unchanged.company_id == company.id
      assert unchanged.parent_id == nil
      assert Goals.get_goal!(b.id).parent_id == a.id

      result =
        render_submit(view, "save", %{
          "goal" => %{
            "title" => "Live Cycle A renamed",
            "company_id" => foreign_company.id,
            "parent_id" => "",
            "project_id" => project.id
          }
        })

      assert {:error, {:live_redirect, %{to: redirect_path}}} = result
      assert redirect_path == "/goals/#{a.id}"

      updated = Goals.get_goal!(a.id)
      assert updated.title == "Live Cycle A renamed"
      assert updated.company_id == company.id
    end
  end
end
