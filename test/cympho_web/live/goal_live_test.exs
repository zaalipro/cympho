defmodule CymphoWeb.GoalLiveTest do
  use CymphoWeb.LiveCase, async: true

  import Ecto.Query
  import CymphoWeb.R3PageHelpers

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
      {:ok, view, html} = live(conn, "/goals")

      # r3 (v7 L6): one list card; the goal overview is Advanced. The density switch
      # stays in both modes: Detailed holds the floating-work Attach form.
      assert_r3_page(main_doc(view), page: "goals", h1: "Goals", kind: :root, primaries: 0)
      assert has_element?(view, "#goals-list-t", "Goals")
      assert has_element?(view, ".card-h [data-density-switch]")
      refute has_element?(view, ".ui-advanced-only [data-density-switch]")
      assert html =~ "Compact"
      assert html =~ "Detailed"
      assert has_element?(view, ".ui-advanced-only #goal-overview-t", "Goals overview")
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

      assert html =~ "Goals overview"
      assert html =~ "Link floating work to strategy"
      assert html =~ "Open unlinked task"
      assert html =~ "Attach"
      assert html =~ "Needs link"
      assert html =~ "Blocked goals"
      # Detailed density shows alignment and the Attach form in Simple mode too, as before.
      assert has_element?(view, "#goal-alignment-t", "Mission alignment")
      refute has_element?(view, ".ui-advanced-only #goal-alignment-t")
      assert html =~ "75% of open work is goal-linked"
      assert has_element?(view, "#goal-risk-t", "Highest-risk floating work")
      refute has_element?(view, ".ui-advanced-only #goal-risk-t")
      refute has_element?(view, ".ui-advanced-only form[phx-submit='link_issue_to_goal']")
      assert html =~ "Goal page floating issue"
      assert has_element?(view, "#goal-risk-#{floating.id} .lr-tr .prio", "Critical")
      # A High or Critical goal keeps its priority on the row.
      assert has_element?(view, "[id^='goals-'] .lr-tr .prio", "High")

      assert has_element?(
               view,
               "[id^='goals-'] a.rt2[href='/goals/#{mission.id}']",
               "Goal page mission"
             )

      assert has_element?(view, "[id^='goals-'] .rm", "1/4 tasks")
      assert has_element?(view, "[id^='goals-'] .lr-st", "1 blocked")
      assert has_element?(view, "[id^='goals-'] .lr-tr", "25%")
      assert has_element?(view, "#goal-menu-#{mission.id} button[phx-click='delete_goal']")
      assert has_element?(view, "#goal-menu-#{mission.id} a[href='/goals/#{mission.id}/edit']")

      html =
        view
        |> element("form[phx-submit='link_issue_to_goal']")
        |> render_submit(%{"issue_id" => floating.id, "goal_id" => mission.id})

      assert html =~ "100% of open work is goal-linked"
      assert html =~ "No open unlinked tasks in this company."
      assert has_element?(view, "[id^='goals-'] .rm", "1/5 tasks")
      assert has_element?(view, "[id^='goals-'] .lr-tr", "20%")

      {:ok, linked_issue} = Issues.get_issue(floating.id)
      assert linked_issue.goal_id == mission.id
      assert linked_issue.project_id == project.id
    end

    test "a goal whose only signal is work in review says so on its row in Simple", %{
      conn: conn,
      current_company: company
    } do
      {:ok, goal} =
        Goals.create_goal(%{title: "Review only goal", company_id: company.id})

      # Recently updated, nothing blocked: neither "blocked" nor "Idle" applies.
      for status <- [:todo, :in_review] do
        {:ok, _issue} =
          Issues.create_issue(%{
            title: "Review only #{status}",
            company_id: company.id,
            goal_id: goal.id,
            status: status
          })
      end

      {:ok, view, _html} = live(conn, "/goals")

      assert has_element?(view, "#goals-#{goal.id} .lr-st", "1 in review")
      refute has_element?(view, ".ui-advanced-only #goals-#{goal.id}")
      refute has_element?(view, "#goals-#{goal.id} .ui-advanced-only", "in review")
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

      {:ok, view, html} = live(conn, "/goals/#{goal.id}")

      # r3 (v7 L8): a deep page; progress is one strip, linked tasks are rows.
      assert_r3_page(main_doc(view),
        page: "goal",
        h1: "Show page mission",
        kind: :deep,
        parent: "Goals",
        primaries: 0
      )

      assert has_element?(view, "#goal-progress-t", "Progress")
      assert html =~ "50% complete"
      assert html =~ "Linked work"
      assert html =~ "Moved this week"
      assert html =~ "Show page todo"
      assert has_element?(view, "#goal-work-t + .meta", "2 shown")
      assert has_element?(view, "a[href='/goals/#{goal.id}/edit']", "Edit")
    end

    test "linked tasks keep their High and Critical priority", %{
      conn: conn,
      current_company: company
    } do
      {:ok, goal} =
        Goals.create_goal(%{
          title: "Priority mission",
          company_id: company.id,
          goal_type: :mission
        })

      {:ok, urgent} =
        Issues.create_issue(%{
          title: "Urgent linked",
          company_id: company.id,
          goal_id: goal.id,
          priority: :critical
        })

      {:ok, quiet} =
        Issues.create_issue(%{
          title: "Quiet linked",
          company_id: company.id,
          goal_id: goal.id,
          priority: :low
        })

      {:ok, view, _html} = live(conn, "/goals/#{goal.id}")

      assert has_element?(view, "#goal-task-#{urgent.id} .lr-tr .prio", "Critical")
      refute has_element?(view, "#goal-task-#{quiet.id} .prio")
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

      # One quiet line, not a progress panel and a list both saying it is empty.
      assert html =~ "Nothing linked yet"
      refute html =~ "% complete"
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
      assert html =~ "Nothing linked yet"
    end
  end

  describe "Goals new" do
    test "renders the alignment planning form", %{conn: conn} do
      {:ok, view, html} = live(conn, "/goals/new")

      # r3 (v7 L7): a form pair; the ? hints and the setup checklist are gone.
      assert_r3_page(main_doc(view),
        page: "goal-form",
        h1: "New goal",
        kind: :deep,
        parent: "Goals",
        primaries: 1
      )

      refute html =~ "Goal alignment plan"
      refute html =~ "Strategy hierarchy"
      refute html =~ "Outcome brief"
      refute html =~ "Setup checklist"
      assert has_element?(view, "form#goal-form.fpair[phx-submit='save']")
      assert has_element?(view, "#goal-form .ink button.pw[type='submit']", "Create goal")
      assert has_element?(view, "#goal-form .ink-h", "After you create it")
      assert has_element?(view, "#goal-form .ink .kh", "to create")
      assert html =~ "Missions sit at the top; an initiative with no parent becomes a mission."
      assert html =~ "Where it fits"
      assert html =~ "Parent goal"
      assert html =~ "New tasks can be linked to it."
      refute has_element?(view, "[data-testid='goal-setup-checklist']")
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

      {:ok, view, html} = live(conn, "/goals/#{goal.id}/edit")

      assert_r3_page(main_doc(view),
        page: "goal-form",
        h1: "Edit Editable mission",
        kind: :deep,
        parent: "Goals",
        primaries: 1
      )

      refute html =~ "Goal alignment plan"
      refute html =~ "Maintenance checklist"
      assert has_element?(view, ".crumb [aria-current]", "Edit goal")
      assert has_element?(view, "#goal-form .ink button.pw[type='submit']", "Save goal")
      assert has_element?(view, "#goal-form .ink-h", "After you save")
      assert has_element?(view, "#goal-form .ink a[href='/goals/#{goal.id}']", "Cancel")
      assert html =~ "Parent goal"
      assert html =~ "No project context"
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
