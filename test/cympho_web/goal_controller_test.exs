defmodule CymphoWeb.GoalControllerTest do
  use CymphoWeb.ConnCase, async: true

  alias Cympho.Companies
  alias Cympho.Goals
  alias Cympho.Projects

  setup %{conn: conn} do
    {conn, _user, company} = register_and_log_in_user(conn)
    unique = System.unique_integer([:positive])

    {:ok, project} =
      Projects.create_project(%{
        name: "Goal API Project #{unique}",
        prefix: project_prefix("GA", unique),
        company_id: company.id
      })

    {:ok, other_company} =
      Companies.create_company(%{
        name: "Other Goal API Company #{unique}",
        slug: "other-goal-api-#{unique}"
      })

    {:ok, other_project} =
      Projects.create_project(%{
        name: "Other Goal API Project #{unique}",
        prefix: project_prefix("OG", unique),
        company_id: other_company.id
      })

    {:ok, other_parent} =
      Goals.create_goal(%{
        title: "Other API parent #{unique}",
        company_id: other_company.id,
        project_id: other_project.id
      })

    {:ok,
     conn: conn,
     company: company,
     project: project,
     other_company: other_company,
     other_project: other_project,
     other_parent: other_parent,
     unique: unique}
  end

  test "create stamps the authenticated company over a forged company_id", %{
    conn: conn,
    company: company,
    project: project,
    other_company: other_company,
    unique: unique
  } do
    title = "Stamped API goal #{unique}"

    conn =
      post(conn, ~p"/api/goals", %{
        "goal" => %{
          "title" => title,
          "company_id" => other_company.id,
          "project_id" => project.id
        }
      })

    goal_id = json_response(conn, 201)["data"]["id"]
    goal = Goals.get_goal!(goal_id)
    assert goal.company_id == company.id
    assert goal.project_id == project.id
  end

  test "create hides forged project and parent references", %{
    conn: conn,
    company: company,
    other_company: other_company,
    other_project: other_project,
    other_parent: other_parent,
    unique: unique
  } do
    project_title = "Forged project API goal #{unique}"

    conn =
      post(conn, ~p"/api/goals", %{
        "goal" => %{
          "title" => project_title,
          "company_id" => other_company.id,
          "project_id" => other_project.id
        }
      })

    assert json_response(conn, 404)

    parent_title = "Forged parent API goal #{unique}"

    conn =
      post(recycle(conn), ~p"/api/goals", %{
        "goal" => %{
          "title" => parent_title,
          "company_id" => other_company.id,
          "parent_id" => other_parent.id
        }
      })

    assert json_response(conn, 404)

    for title <- [project_title, parent_title] do
      refute Enum.any?(Goals.list_goals_by_company(company.id), &(&1.title == title))
      refute Enum.any?(Goals.list_goals_by_company(other_company.id), &(&1.title == title))
    end
  end

  test "update ignores forged company_id and rejects foreign relationships", %{
    conn: conn,
    company: company,
    project: project,
    other_company: other_company,
    other_project: other_project,
    other_parent: other_parent,
    unique: unique
  } do
    {:ok, goal} =
      Goals.create_goal(%{
        title: "API tenant goal #{unique}",
        company_id: company.id,
        project_id: project.id
      })

    conn =
      patch(conn, ~p"/api/goals/#{goal.id}", %{
        "goal" => %{
          "title" => "API tenant goal updated #{unique}",
          "company_id" => other_company.id
        }
      })

    assert json_response(conn, 200)["data"]["title"] == "API tenant goal updated #{unique}"
    assert Goals.get_goal!(goal.id).company_id == company.id

    conn =
      patch(recycle(conn), ~p"/api/goals/#{goal.id}", %{
        "goal" => %{"project_id" => other_project.id}
      })

    assert json_response(conn, 404)

    conn =
      patch(recycle(conn), ~p"/api/goals/#{goal.id}", %{
        "goal" => %{"parent_id" => other_parent.id}
      })

    assert json_response(conn, 404)

    unchanged = Goals.get_goal!(goal.id)
    assert unchanged.company_id == company.id
    assert unchanged.project_id == project.id
    assert unchanged.parent_id == nil
  end

  test "update rejects an A to B to A cycle", %{
    conn: conn,
    company: company,
    project: project,
    unique: unique
  } do
    {:ok, a} =
      Goals.create_goal(%{
        title: "API cycle A #{unique}",
        company_id: company.id,
        project_id: project.id
      })

    {:ok, b} =
      Goals.create_goal(%{
        title: "API cycle B #{unique}",
        company_id: company.id,
        project_id: project.id,
        parent_id: a.id
      })

    conn = patch(conn, ~p"/api/goals/#{a.id}", %{"goal" => %{"parent_id" => b.id}})

    assert %{"errors" => %{"parent_id" => ["would create a cycle"]}} =
             json_response(conn, 422)

    assert Goals.get_goal!(a.id).parent_id == nil
    assert Goals.get_goal!(b.id).parent_id == a.id
  end

  defp project_prefix(base, unique) do
    suffix =
      unique
      |> Integer.digits(26)
      |> Enum.map_join(fn digit -> <<?A + digit>> end)
      |> String.slice(0, 8)

    base <> suffix
  end
end
