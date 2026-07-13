defmodule CymphoWeb.LaunchItemControllerTest do
  use CymphoWeb.ConnCase, async: true

  alias Cympho.{Companies, LaunchItems, Users}

  setup %{conn: conn} do
    {conn, current_user, company} = register_and_log_in_user(conn)
    unique = System.unique_integer([:positive])

    {:ok, backup_owner} =
      Users.create_user(%{
        email: "launch-api-owner-#{unique}@example.com",
        name: "Launch API Owner #{unique}",
        password: "password1234"
      })

    {:ok, _membership} =
      Companies.create_membership(%{
        user_id: backup_owner.id,
        company_id: company.id,
        role: "member",
        is_board_member: false
      })

    {:ok, other_company} =
      Companies.create_company(%{
        name: "Other Launch Co #{unique}",
        slug: "other-launch-co-#{unique}"
      })

    {:ok, _other_membership} =
      Companies.create_membership(%{
        user_id: current_user.id,
        company_id: other_company.id,
        role: "member",
        is_board_member: false
      })

    %{
      conn: conn,
      company: company,
      current_user: current_user,
      backup_owner: backup_owner,
      other_company: other_company
    }
  end

  defp launch_item(company, owner, attrs) do
    LaunchItems.create_launch_item(
      Map.merge(
        %{
          title: "Launch Item #{System.unique_integer([:positive])}",
          owner_user_id: owner.id,
          company_id: company.id
        },
        attrs
      )
    )
  end

  describe "GET /api/launch-items" do
    test "lists launch items for the current company with blocked work first", %{
      conn: conn,
      company: company,
      current_user: current_user,
      backup_owner: backup_owner,
      other_company: other_company
    } do
      {:ok, first} = launch_item(company, current_user, %{title: "First", status: "planned"})

      {:ok, second} =
        launch_item(company, backup_owner, %{
          title: "Second",
          status: "in_progress",
          is_blocked: true
        })

      {:ok, _other} = launch_item(other_company, current_user, %{title: "Other"})

      conn = get(conn, ~p"/api/launch-items")
      assert %{"data" => items} = json_response(conn, 200)

      assert Enum.map(items, & &1["title"]) == ["Second", "First"]
      assert Enum.map(items, & &1["id"]) == [second.id, first.id]
      assert Enum.map(items, & &1["owner_user_id"]) == [backup_owner.id, current_user.id]
      refute Enum.any?(items, &(&1["title"] == "Other"))
    end
  end

  describe "POST /api/launch-items" do
    test "creates a launch item with default owner, status, and blocked flag", %{
      conn: conn,
      current_user: current_user
    } do
      params = %{
        "launch_item" => %{
          "title" => "Track launch readiness"
        }
      }

      conn = post(conn, ~p"/api/launch-items", params)
      assert %{"data" => data} = json_response(conn, 201)
      assert data["title"] == "Track launch readiness"
      assert data["owner_user_id"] == current_user.id
      assert data["owner"]["email"] == current_user.email
      assert data["status"] == "planned"
      refute data["is_blocked"]
    end

    test "rejects an invalid status", %{conn: conn} do
      params = %{
        "launch_item" => %{
          "title" => "Invalid status",
          "status" => "launching"
        }
      }

      conn = post(conn, ~p"/api/launch-items", params)
      assert %{"errors" => _} = json_response(conn, 422)
    end
  end

  describe "PATCH /api/launch-items/:id" do
    test "updates a launch item", %{
      conn: conn,
      company: company,
      current_user: current_user,
      backup_owner: backup_owner
    } do
      {:ok, launch_item} =
        launch_item(company, current_user, %{title: "Original", status: "planned"})

      params = %{
        "launch_item" => %{
          "title" => "Updated",
          "owner_user_id" => backup_owner.id,
          "status" => "completed",
          "is_blocked" => true
        }
      }

      conn = patch(conn, ~p"/api/launch-items/#{launch_item.id}", params)
      assert %{"data" => data} = json_response(conn, 200)
      assert data["title"] == "Updated"
      assert data["owner_user_id"] == backup_owner.id
      assert data["status"] == "completed"
      assert data["is_blocked"]
    end

    test "rejects an invalid status update", %{
      conn: conn,
      company: company,
      current_user: current_user
    } do
      {:ok, launch_item} =
        launch_item(company, current_user, %{title: "Original", status: "planned"})

      params = %{"launch_item" => %{"status" => "not-a-status"}}

      conn = patch(conn, ~p"/api/launch-items/#{launch_item.id}", params)
      assert %{"errors" => _} = json_response(conn, 422)
    end
  end

  describe "DELETE /api/launch-items/:id" do
    test "deletes a launch item", %{conn: conn, company: company, current_user: current_user} do
      {:ok, launch_item} =
        launch_item(company, current_user, %{title: "Delete me", status: "planned"})

      conn = delete(conn, ~p"/api/launch-items/#{launch_item.id}")
      assert response(conn, 204)

      assert {:error, :not_found} =
               LaunchItems.get_company_launch_item(company.id, launch_item.id)
    end
  end
end
