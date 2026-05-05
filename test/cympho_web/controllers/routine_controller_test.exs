defmodule CymphoWeb.RoutineControllerTest do
  use CymphoWeb.ConnCase

  alias Cympho.Routines

  setup %{conn: conn} do
    {conn, user, company} = register_and_log_in_user(conn)
    {:ok, conn: conn, user: user, company: company}
  end

  defp company_routine(company, attrs) do
    {:ok, agent} =
      Cympho.Agents.create_agent(%{
        name: "Routine Agent #{System.unique_integer([:positive])}",
        role: "engineer",
        company_id: company.id,
        url_key: "ra-#{System.unique_integer([:positive])}"
      })

    Routines.create_routine(Map.merge(%{agent_id: agent.id}, attrs))
  end

  describe "index" do
    test "lists all routines", %{conn: conn, company: company} do
      {:ok, _} = company_routine(company, %{name: "Routine 1"})
      {:ok, _} = company_routine(company, %{name: "Routine 2"})

      conn = get(conn, ~p"/api/routines")
      assert %{"data" => routines} = json_response(conn, 200)
      assert length(routines) >= 2
    end
  end

  describe "show" do
    test "shows a single routine", %{conn: conn, company: company} do
      {:ok, routine} = company_routine(company, %{name: "Test Routine"})

      conn = get(conn, ~p"/api/routines/#{routine.id}")
      assert %{"data" => data} = json_response(conn, 200)
      assert data["name"] == "Test Routine"
      assert data["status"] == "active"
    end

    test "returns 404 for non-existent routine", %{conn: conn} do
      conn = get(conn, ~p"/api/routines/00000000-0000-0000-0000-000000000000")
      assert json_response(conn, 404)
    end
  end

  describe "create" do
    test "creates a routine with valid data", %{conn: conn, company: company} do
      {:ok, agent} =
        Cympho.Agents.create_agent(%{
          name: "Create Agent",
          role: "engineer",
          company_id: company.id,
          url_key: "ca-#{System.unique_integer([:positive])}"
        })

      params = %{
        "routine" => %{
          "name" => "New Routine",
          "description" => "A test routine",
          "agent_id" => agent.id
        }
      }

      conn = post(conn, ~p"/api/routines", params)
      assert %{"data" => data} = json_response(conn, 201)
      assert data["name"] == "New Routine"
      assert data["description"] == "A test routine"
    end

    test "returns error for missing name", %{conn: conn} do
      params = %{"routine" => %{}}
      conn = post(conn, ~p"/api/routines", params)
      assert json_response(conn, 422)
    end
  end

  describe "update" do
    test "updates a routine", %{conn: conn, company: company} do
      {:ok, routine} = company_routine(company, %{name: "Original"})

      params = %{"routine" => %{"name" => "Updated"}}
      conn = patch(conn, ~p"/api/routines/#{routine.id}", params)
      assert %{"data" => data} = json_response(conn, 200)
      assert data["name"] == "Updated"
    end

    test "returns 404 for non-existent routine", %{conn: conn} do
      params = %{"routine" => %{"name" => "Updated"}}
      conn = patch(conn, ~p"/api/routines/00000000-0000-0000-0000-000000000000", params)
      assert json_response(conn, 404)
    end
  end

  describe "delete" do
    test "deletes a routine", %{conn: conn, company: company} do
      {:ok, routine} = company_routine(company, %{name: "To Delete"})
      conn = delete(conn, ~p"/api/routines/#{routine.id}")
      assert response(conn, 204)
    end

    test "returns 404 for non-existent routine", %{conn: conn} do
      conn = delete(conn, ~p"/api/routines/00000000-0000-0000-0000-000000000000")
      assert json_response(conn, 404)
    end
  end

  describe "pause" do
    test "pauses an active routine", %{conn: conn, company: company} do
      {:ok, routine} = company_routine(company, %{name: "Test"})
      conn = patch(conn, ~p"/api/routines/#{routine.id}/pause")
      assert %{"data" => data} = json_response(conn, 200)
      assert data["status"] == "paused"
    end

    test "returns error when pausing a non-active routine", %{conn: conn, company: company} do
      {:ok, routine} = company_routine(company, %{name: "Test", status: :paused})
      conn = patch(conn, ~p"/api/routines/#{routine.id}/pause")
      assert json_response(conn, 422)
    end
  end

  describe "resume" do
    test "resumes a paused routine", %{conn: conn, company: company} do
      {:ok, routine} = company_routine(company, %{name: "Test"})
      {:ok, _} = Routines.pause_routine(routine)
      conn = patch(conn, ~p"/api/routines/#{routine.id}/resume")
      assert %{"data" => data} = json_response(conn, 200)
      assert data["status"] == "active"
    end

    test "returns error when resuming a non-paused routine", %{conn: conn, company: company} do
      {:ok, routine} = company_routine(company, %{name: "Test"})
      conn = patch(conn, ~p"/api/routines/#{routine.id}/resume")
      assert json_response(conn, 422)
    end
  end

  describe "archive" do
    test "archives an active routine", %{conn: conn, company: company} do
      {:ok, routine} = company_routine(company, %{name: "Test"})
      conn = patch(conn, ~p"/api/routines/#{routine.id}/archive")
      assert %{"data" => data} = json_response(conn, 200)
      assert data["status"] == "archived"
    end

    test "returns error when archiving an already archived routine", %{
      conn: conn,
      company: company
    } do
      {:ok, routine} = company_routine(company, %{name: "Test"})
      {:ok, _} = Routines.archive_routine(routine)
      conn = patch(conn, ~p"/api/routines/#{routine.id}/archive")
      assert json_response(conn, 422)
    end
  end
end
