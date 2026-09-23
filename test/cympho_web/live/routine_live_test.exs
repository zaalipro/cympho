defmodule CymphoWeb.RoutineLiveTest do
  use CymphoWeb.LiveCase, async: true

  import Phoenix.LiveViewTest
  alias Cympho.{Agents, Projects, RoutineTriggers, Routines}

  test "routine form params fail closed when no company is assigned" do
    socket = %{assigns: %{current_company: nil}}

    assert {:error, :not_found} =
             CymphoWeb.RoutineLive.FormHelpers.scoped_routine_params(
               socket,
               %{"name" => "Forged", "company_id" => Ecto.UUID.generate()},
               put_company_scope: true
             )
  end

  defp create_routine(attrs) do
    attrs
    |> Map.put_new(:company_id, current_company_id())
    |> Routines.create_routine()
  end

  defp create_agent(attrs) do
    attrs
    |> Map.put_new(:company_id, current_company_id())
    |> Agents.create_agent()
  end

  defp create_project(attrs) do
    unique = System.unique_integer([:positive])

    attrs
    |> Map.put_new(:company_id, current_company_id())
    |> Map.put_new(:prefix, "R#{alpha_suffix(unique)}")
    |> Projects.create_project()
  end

  defp alpha_suffix(number), do: alpha_suffix(number, "")

  defp alpha_suffix(0, ""), do: "A"
  defp alpha_suffix(0, acc), do: String.slice(acc, 0, 9)

  defp alpha_suffix(number, acc) do
    alpha_suffix(div(number, 26), <<?A + rem(number, 26)>> <> acc)
  end

  describe "Index" do
    test "renders the routines page", %{conn: conn} do
      {:ok, _routine} = create_routine(%{name: "Rendered Routine"})

      {:ok, _view, html} = live(conn, "/routines")
      assert html =~ "Routines"
      assert html =~ "Routine command"
      assert html =~ "Compact"
      assert html =~ "Detailed"
      refute html =~ "Routine Health"
    end

    test "shows a single empty state when no routines exist", %{conn: conn} do
      {:ok, view, html} = live(conn, "/routines?density=detailed")
      # The command card and health card both restated the list's empty state;
      # with nothing to run only the list empty state and the header CTA remain.
      refute has_element?(view, "[data-testid='routine-command']")
      refute has_element?(view, "[data-testid='routine-health']")
      assert html =~ "No routines yet"
      assert html =~ "Create the first routine to schedule autonomous work."
      assert html =~ "New Routine"
    end

    test "shows routine health diagnostics", %{conn: conn} do
      {:ok, routine} = create_routine(%{name: "Triggerless Routine"})

      {:ok, view, html} = live(conn, "/routines?density=detailed")
      assert has_element?(view, "[data-testid='routine-command']")
      assert has_element?(view, "[data-testid='routine-next-action']")
      assert html =~ "Add trigger to routine"
      assert html =~ "Triggerless Routine"
      assert html =~ "Open routine"
      assert has_element?(view, "[data-testid='routine-health']")
      assert html =~ "Needs attention"
      assert html =~ "Trigger gaps"
      assert html =~ "Add triggers"
      assert html =~ "Do this next"
      assert html =~ "Open trigger gaps"

      assert has_element?(
               view,
               "[data-testid='routine-next-action'] a[href='/routines/#{routine.id}']"
             )
    end

    test "lists routines with status badges", %{conn: conn} do
      {:ok, _routine} = create_routine(%{name: "Test Routine Alpha"})

      {:ok, _view, html} = live(conn, "/routines")
      assert html =~ "Test Routine Alpha"
      assert html =~ "Active"
    end

    test "scopes routine list to the current company", %{conn: conn, current_company: company} do
      {:ok, other_company} =
        Cympho.Companies.create_company(%{
          name: "Other Routine Co",
          slug: "other-routine-#{System.unique_integer([:positive])}"
        })

      {:ok, _visible} = create_routine(%{name: "Visible Routine"})

      {:ok, foreign} =
        Routines.create_routine(%{
          name: "Foreign Routine",
          company_id: other_company.id
        })

      {:ok, _view, html} = live(conn, "/routines")

      assert html =~ "Visible Routine"
      refute html =~ "Foreign Routine"
      refute company.id == other_company.id
      assert foreign.company_id == other_company.id
    end

    test "does not expose a foreign-owned routine through a local agent association", %{
      conn: conn
    } do
      {:ok, other_company} =
        Cympho.Companies.create_company(%{
          name: "Foreign Routine With Local Agent",
          slug: "foreign-local-agent-#{System.unique_integer([:positive])}"
        })

      {:ok, local_agent} = create_agent(%{name: "Local Owner", role: :engineer})

      {:ok, foreign} =
        Routines.create_routine(%{name: "Do Not Expose", company_id: other_company.id})

      foreign =
        foreign
        |> Ecto.Changeset.change(agent_id: local_agent.id)
        |> Cympho.Repo.update!()

      {:ok, _view, html} = live(conn, "/routines")
      refute html =~ "Do Not Expose"
      assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, "/routines/#{foreign.id}")

      assert {:error, {:live_redirect, %{to: "/routines"}}} =
               live(conn, "/routines/#{foreign.id}/edit")
    end

    test "shows pause button for active routines", %{conn: conn} do
      {:ok, routine} = create_routine(%{name: "Active One"})

      {:ok, view, _html} = live(conn, "/routines")
      assert has_element?(view, "#routine-#{routine.id} button[phx-click='pause_routine']")
    end

    test "shows resume button for paused routines", %{conn: conn} do
      {:ok, routine} = create_routine(%{name: "Paused One"})
      {:ok, _} = Routines.pause_routine(routine)

      {:ok, view, _html} = live(conn, "/routines")
      assert has_element?(view, "#routine-#{routine.id} button[phx-click='resume_routine']")
    end

    test "pauses an active routine", %{conn: conn} do
      {:ok, routine} = create_routine(%{name: "To Pause"})

      {:ok, view, _html} = live(conn, "/routines")

      view
      |> element("#routine-#{routine.id} button[phx-click='pause_routine']")
      |> render_click()

      html = render(view)
      assert html =~ "Paused"
    end

    test "resumes a paused routine", %{conn: conn} do
      {:ok, routine} = create_routine(%{name: "To Resume"})
      {:ok, _} = Routines.pause_routine(routine)

      {:ok, view, _html} = live(conn, "/routines")

      view
      |> element("#routine-#{routine.id} button[phx-click='resume_routine']")
      |> render_click()

      html = render(view)
      assert html =~ "Active"
    end

    @tag membership_role: "admin"
    test "archives a routine", %{conn: conn} do
      {:ok, routine} = create_routine(%{name: "To Archive"})

      {:ok, view, _html} = live(conn, "/routines")

      view
      |> element("#routine-#{routine.id} button[phx-click='delete_routine']")
      |> render_click()

      html = render(view)
      assert html =~ "Archived"
    end

    test "links to new routine page", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/routines")
      assert has_element?(view, "a[href='/routines/new']")
    end

    test "links to routine show page", %{conn: conn} do
      {:ok, routine} = create_routine(%{name: "Viewable"})

      {:ok, view, _html} = live(conn, "/routines")
      assert has_element?(view, "a[href='/routines/#{routine.id}']")
    end
  end

  describe "Show" do
    test "renders routine details", %{conn: conn} do
      {:ok, routine} = create_routine(%{name: "Show Routine", description: "A desc"})

      {:ok, _view, html} = live(conn, "/routines/#{routine.id}")
      assert html =~ "Show Routine"
      assert html =~ "A desc"
      assert html =~ "Active"
    end

    test "shows run history section", %{conn: conn} do
      {:ok, routine} = create_routine(%{name: "History Routine"})

      {:ok, _view, html} = live(conn, "/routines/#{routine.id}")
      assert html =~ "Run History"
    end

    test "shows empty state for runs", %{conn: conn} do
      {:ok, routine} = create_routine(%{name: "No Runs"})

      {:ok, _view, html} = live(conn, "/routines/#{routine.id}")
      assert html =~ "No runs yet"
      assert html =~ "Add trigger"
    end

    test "renders a cron field and creates a schedule trigger", %{conn: conn} do
      {:ok, routine} = create_routine(%{name: "Needs a Cron"})

      {:ok, view, html} = live(conn, "/routines/#{routine.id}")
      assert html =~ "name=\"cron_expression\""
      assert has_element?(view, "form[phx-submit='create_schedule_trigger']")

      view
      |> form("form[phx-submit='create_schedule_trigger']", %{cron_expression: "0 9 * * *"})
      |> render_submit()

      flash = :sys.get_state(view.pid).socket.assigns.flash
      assert Phoenix.Flash.get(flash, :info) == "Trigger created"

      triggers = RoutineTriggers.list_triggers(routine.id)
      assert Enum.any?(triggers, &(&1.type == "schedule" and &1.cron_expression == "0 9 * * *"))
    end

    test "invalid cron flashes an error", %{conn: conn} do
      {:ok, routine} = create_routine(%{name: "Bad Cron"})

      {:ok, view, _html} = live(conn, "/routines/#{routine.id}")

      view
      |> form("form[phx-submit='create_schedule_trigger']", %{cron_expression: "not-a-cron"})
      |> render_submit()

      flash = :sys.get_state(view.pid).socket.assigns.flash
      assert Phoenix.Flash.get(flash, :error) == "Invalid cron expression"
      assert RoutineTriggers.list_triggers(routine.id) == []
    end

    test "redirects to root for non-existent routine", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/"}}} =
               live(conn, "/routines/00000000-0000-0000-0000-000000000000")
    end

    test "redirects when a routine belongs to another company", %{conn: conn} do
      {:ok, other_company} =
        Cympho.Companies.create_company(%{
          name: "Foreign Show Routine Co",
          slug: "foreign-show-routine-#{System.unique_integer([:positive])}"
        })

      {:ok, routine} =
        Routines.create_routine(%{
          name: "Foreign Show Routine",
          company_id: other_company.id
        })

      assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, "/routines/#{routine.id}")
    end
  end

  describe "New" do
    test "forged company id cannot override the current company", %{
      conn: conn,
      current_company: company
    } do
      {:ok, other_company} =
        Cympho.Companies.create_company(%{
          name: "Forged Routine Company",
          slug: "forged-routine-#{System.unique_integer([:positive])}"
        })

      {:ok, view, _html} = live(conn, "/routines/new")

      assert {:error, {:live_redirect, %{to: "/routines/" <> id}}} =
               render_submit(view, "save", %{
                 "routine" => %{
                   "name" => "Tenant-bound routine",
                   "company_id" => other_company.id
                 }
               })

      assert Routines.get_routine!(id).company_id == company.id
    end

    test "renders the new routine form", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/routines/new")
      assert html =~ "New Routine"
      assert html =~ "Create Routine"
      assert html =~ "Routine launch plan"
      assert html =~ "Setup checklist"
      assert html =~ "Default owner"
      assert html =~ "Project context"
      assert html =~ "Run policy"
    end

    test "renders current-company owner and project choices", %{conn: conn} do
      {:ok, _agent} = create_agent(%{name: "Ops CTO", role: :cto})
      {:ok, _project} = create_project(%{name: "Ops Platform"})

      {:ok, _view, html} = live(conn, "/routines/new")

      assert html =~ "Ops CTO · CTO"
      assert html =~ "Ops Platform"
      assert html =~ "No default owner"
      assert html =~ "No project context"
    end

    test "creates a routine and redirects to show", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/routines/new")

      result =
        view
        |> form("form[phx-submit=save]", routine: %{name: "Brand New Routine"})
        |> render_submit()

      assert {:error, {:live_redirect, %{to: "/routines/" <> _}}} = result

      assert Enum.any?(
               Cympho.Routines.list_routines(company_id: current_company_id()),
               &(&1.name == "Brand New Routine")
             )
    end

    test "creates a routine with owner and project context", %{conn: conn} do
      {:ok, agent} = create_agent(%{name: "Release Captain", role: :release_engineer})
      {:ok, project} = create_project(%{name: "Release Ops"})
      {:ok, view, _html} = live(conn, "/routines/new")

      result =
        view
        |> form("form[phx-submit=save]",
          routine: %{
            name: "Release Readiness",
            description: "Check blockers and create follow-up work.",
            agent_id: agent.id,
            project_id: project.id,
            priority: "high",
            concurrency_policy: "skip_if_active",
            catch_up_policy: "enqueue_missed_with_cap",
            catch_up_cap: "3"
          }
        )
        |> render_submit()

      assert {:error, {:live_redirect, %{to: "/routines/" <> _}}} = result

      routine =
        Cympho.Routines.list_routines(company_id: current_company_id())
        |> Enum.find(&(&1.name == "Release Readiness"))

      assert routine.agent_id == agent.id
      assert routine.project_id == project.id
      assert routine.priority == :high
      assert routine.concurrency_policy == :skip_if_active
      assert routine.catch_up_policy == :enqueue_missed_with_cap
      assert routine.catch_up_cap == 3
    end

    test "shows error for empty name", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/routines/new")

      html =
        view
        |> form("form[phx-submit=save]", routine: %{name: ""})
        |> render_submit()

      assert html =~ "can&#39;t be blank"
    end
  end

  describe "Edit" do
    test "updates an accessible legacy null-company routine without changing ownership", %{
      conn: conn
    } do
      {:ok, agent} = create_agent(%{name: "Legacy Owner", role: :engineer})
      {:ok, routine} = Routines.create_routine(%{name: "Legacy routine", agent_id: agent.id})
      {:ok, view, _html} = live(conn, "/routines/#{routine.id}/edit")

      assert {:error, {:live_redirect, %{to: "/routines/" <> _}}} =
               render_submit(view, "save", %{"routine" => %{"name" => "Legacy updated"}})

      updated = Routines.get_routine!(routine.id)
      assert updated.name == "Legacy updated"
      assert updated.company_id == nil
    end

    test "forged company id on edit cannot move a routine", %{conn: conn} do
      {:ok, other_company} =
        Cympho.Companies.create_company(%{
          name: "Forged Edit Company",
          slug: "forged-edit-#{System.unique_integer([:positive])}"
        })

      {:ok, routine} = create_routine(%{name: "Stay local"})
      {:ok, view, _html} = live(conn, "/routines/#{routine.id}/edit")

      render_submit(view, "save", %{
        "routine" => %{"name" => "Moved", "company_id" => other_company.id}
      })

      changeset = :sys.get_state(view.pid).socket.assigns.changeset
      assert Keyword.has_key?(changeset.errors, :company_id)
      assert Routines.get_routine!(routine.id).company_id == routine.company_id
      assert Routines.get_routine!(routine.id).name == "Stay local"
    end

    test "rejects an owner and project from another company", %{conn: conn} do
      {:ok, other_company} =
        Cympho.Companies.create_company(%{
          name: "Foreign Edit References",
          slug: "foreign-edit-refs-#{System.unique_integer([:positive])}"
        })

      {:ok, foreign_agent} =
        create_agent(%{name: "Foreign Agent", role: :engineer, company_id: other_company.id})

      {:ok, foreign_project} =
        create_project(%{name: "Foreign Project", company_id: other_company.id})

      {:ok, routine} = create_routine(%{name: "Local references only"})
      {:ok, view, _html} = live(conn, "/routines/#{routine.id}/edit")

      render_submit(view, "save", %{
        "routine" => %{
          "name" => "Changed",
          "agent_id" => foreign_agent.id,
          "project_id" => foreign_project.id
        }
      })

      assert Routines.get_routine!(routine.id).name == "Local references only"
      assert Routines.get_routine!(routine.id).agent_id == nil
      assert Routines.get_routine!(routine.id).project_id == nil
    end

    test "renders the edit form with existing values", %{conn: conn} do
      {:ok, routine} = create_routine(%{name: "Edit Me"})

      {:ok, _view, html} = live(conn, "/routines/#{routine.id}/edit")
      assert html =~ "Edit Routine"
      assert html =~ "Save Changes"
      assert html =~ "Maintain the recurring work packet"
      assert html =~ "Default owner"
      assert html =~ "Project context"
    end

    test "updates routine and redirects to show", %{conn: conn} do
      {:ok, routine} = create_routine(%{name: "Before Edit"})

      {:ok, view, _html} = live(conn, "/routines/#{routine.id}/edit")

      result =
        view
        |> form("form[phx-submit=save]", routine: %{name: "After Edit"})
        |> render_submit()

      # On submit redirects to show page
      assert {:error, {:live_redirect, %{to: "/routines/" <> _}}} = result

      updated = Cympho.Routines.get_routine!(routine.id)
      assert updated.name == "After Edit"
    end

    test "updates routine owner and project context", %{conn: conn} do
      {:ok, routine} = create_routine(%{name: "Contextless"})
      {:ok, agent} = create_agent(%{name: "Ops Engineer", role: :engineer})
      {:ok, project} = create_project(%{name: "Autonomy Ops"})

      {:ok, view, _html} = live(conn, "/routines/#{routine.id}/edit")

      result =
        view
        |> form("form[phx-submit=save]",
          routine: %{
            name: "Contextful",
            agent_id: agent.id,
            project_id: project.id
          }
        )
        |> render_submit()

      assert {:error, {:live_redirect, %{to: "/routines/" <> _}}} = result

      updated = Cympho.Routines.get_routine!(routine.id)
      assert updated.name == "Contextful"
      assert updated.agent_id == agent.id
      assert updated.project_id == project.id
    end
  end
end
