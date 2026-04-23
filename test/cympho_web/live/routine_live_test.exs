defmodule CymphoWeb.RoutineLiveTest do
  use CymphoWeb.LiveCase, async: true

  import Phoenix.LiveViewTest
  alias Cympho.Routines

  describe "Index" do
    test "renders the routines page", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/routines")
      assert html =~ "Routines"
    end

    test "shows empty state when no routines exist", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/routines")
      assert html =~ "No routines yet"
    end

    test "lists routines with status badges", %{conn: conn} do
      {:ok, _routine} = Routines.create_routine(%{name: "Test Routine Alpha"})

      {:ok, _view, html} = live(conn, "/routines")
      assert html =~ "Test Routine Alpha"
      assert html =~ "active"
    end

    test "shows pause button for active routines", %{conn: conn} do
      {:ok, routine} = Routines.create_routine(%{name: "Active One"})

      {:ok, view, _html} = live(conn, "/routines")
      assert has_element?(view, "#routine-#{routine.id} button.pause-btn")
    end

    test "shows resume button for paused routines", %{conn: conn} do
      {:ok, routine} = Routines.create_routine(%{name: "Paused One"})
      {:ok, _} = Routines.pause_routine(routine)

      {:ok, view, _html} = live(conn, "/routines")
      assert has_element?(view, "#routine-#{routine.id} button.resume-btn")
    end

    test "pauses an active routine", %{conn: conn} do
      {:ok, routine} = Routines.create_routine(%{name: "To Pause"})

      {:ok, view, _html} = live(conn, "/routines")
      view |> element("#routine-#{routine.id} button.pause-btn") |> render_click()
      html = render(view)
      assert html =~ "paused"
    end

    test "resumes a paused routine", %{conn: conn} do
      {:ok, routine} = Routines.create_routine(%{name: "To Resume"})
      {:ok, _} = Routines.pause_routine(routine)

      {:ok, view, _html} = live(conn, "/routines")
      view |> element("#routine-#{routine.id} button.resume-btn") |> render_click()
      html = render(view)
      assert html =~ "active"
    end

    test "archives a routine", %{conn: conn} do
      {:ok, routine} = Routines.create_routine(%{name: "To Archive"})

      {:ok, view, _html} = live(conn, "/routines")
      view |> element("#routine-#{routine.id} button.delete-btn") |> render_click()
      html = render(view)
      refute html =~ "To Archive"
    end

    test "links to new routine page", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/routines")
      assert has_element?(view, "a[href='/routines/new']")
    end

    test "links to routine show page", %{conn: conn} do
      {:ok, routine} = Routines.create_routine(%{name: "Viewable"})

      {:ok, view, _html} = live(conn, "/routines")
      assert has_element?(view, "a[href='/routines/#{routine.id}']")
    end
  end

  describe "Show" do
    test "renders routine details", %{conn: conn} do
      {:ok, routine} = Routines.create_routine(%{name: "Show Routine", description: "A desc"})

      {:ok, _view, html} = live(conn, "/routines/#{routine.id}")
      assert html =~ "Show Routine"
      assert html =~ "A desc"
      assert html =~ "active"
    end

    test "shows run history section", %{conn: conn} do
      {:ok, routine} = Routines.create_routine(%{name: "History Routine"})

      {:ok, _view, html} = live(conn, "/routines/#{routine.id}")
      assert html =~ "Run History"
    end

    test "shows empty state for runs", %{conn: conn} do
      {:ok, routine} = Routines.create_routine(%{name: "No Runs"})

      {:ok, _view, html} = live(conn, "/routines/#{routine.id}")
      assert html =~ "No runs yet"
    end

    test "redirects to root for non-existent routine", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/"}}} =
               live(conn, "/routines/00000000-0000-0000-0000-000000000000")
    end
  end

  describe "New" do
    test "renders the new routine form", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/routines/new")
      assert html =~ "New Routine"
      assert html =~ "Create Routine"
    end

    test "creates a routine and redirects to show", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/routines/new")

      html =
        view
        |> form("form[phx-submit=save]", routine: %{name: "Brand New Routine"})
        |> render_submit()

      assert html =~ "Brand New Routine"
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
    test "renders the edit form with existing values", %{conn: conn} do
      {:ok, routine} = Routines.create_routine(%{name: "Edit Me"})

      {:ok, _view, html} = live(conn, "/routines/#{routine.id}/edit")
      assert html =~ "Edit Routine"
      assert html =~ "Update Routine"
    end

    test "updates routine and redirects to show", %{conn: conn} do
      {:ok, routine} = Routines.create_routine(%{name: "Before Edit"})

      {:ok, view, _html} = live(conn, "/routines/#{routine.id}/edit")

      html =
        view
        |> form("form[phx-submit=save]", routine: %{name: "After Edit"})
        |> render_submit()

      assert html =~ "After Edit"
    end
  end
end
