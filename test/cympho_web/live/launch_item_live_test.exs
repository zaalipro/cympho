defmodule CymphoWeb.LaunchItemLiveTest do
  use CymphoWeb.LiveCase, async: false

  import Phoenix.LiveViewTest

  alias Cympho.{Companies, LaunchItems, Users}

  setup %{current_company: company} do
    unique = System.unique_integer([:positive])

    {:ok, owner_a} =
      Users.create_user(%{
        email: "launch-ui-owner-a-#{unique}@example.com",
        name: "Launch UI Owner A #{unique}",
        password: "password1234"
      })

    {:ok, owner_b} =
      Users.create_user(%{
        email: "launch-ui-owner-b-#{unique}@example.com",
        name: "Launch UI Owner B #{unique}",
        password: "password1234"
      })

    {:ok, _membership} =
      Companies.create_membership(%{
        user_id: owner_a.id,
        company_id: company.id,
        role: "member",
        is_board_member: false
      })

    {:ok, _membership} =
      Companies.create_membership(%{
        user_id: owner_b.id,
        company_id: company.id,
        role: "member",
        is_board_member: false
      })

    %{owner_a: owner_a, owner_b: owner_b}
  end

  test "renders the empty state when no launch items exist", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/launch-items")

    assert html =~ "No launch items yet"
    assert html =~ "Create launch item"
  end

  test "can create, edit, complete, and block launch items", %{
    conn: conn,
    current_company: company,
    owner_a: owner_a,
    owner_b: owner_b
  } do
    {:ok, view, html} = live(conn, "/launch-items")

    assert html =~ "Add work to the tracker"
    assert html =~ "No blocked launch items"

    html =
      view
      |> form("#launch-item-create-form",
        launch_item: %{
          title: "Ship launch checklist",
          owner_user_id: owner_a.id,
          status: "planned"
        }
      )
      |> render_submit()

    assert html =~ "Ship launch checklist"
    assert html =~ owner_a.name

    [item] = LaunchItems.list_company_launch_items(company.id)

    html =
      view
      |> form("#launch-item-owner-#{item.id}", %{
        "_id" => item.id,
        "owner_user_id" => owner_b.id
      })
      |> render_change()

    assert html =~ owner_b.name

    assert {:ok, updated_owner} = LaunchItems.get_company_launch_item(company.id, item.id)
    assert updated_owner.owner_user_id == owner_b.id

    html =
      view
      |> element(
        "#launch-item-#{item.id} button[phx-click='update_status'][phx-value-status='completed']"
      )
      |> render_click()

    assert html =~ "Completed"

    assert {:ok, completed_item} = LaunchItems.get_company_launch_item(company.id, item.id)
    assert completed_item.status == "completed"

    html =
      view
      |> element("#launch-item-#{item.id} button[phx-click='toggle_blocked']")
      |> render_click()

    assert html =~ "Unblock"

    assert has_element?(
             view,
             "#blocked-work-view #blocked-launch-item-#{item.id}",
             "Ship launch checklist"
           )

    assert html =~ "Blocked titles"

    assert {:ok, blocked_item} = LaunchItems.get_company_launch_item(company.id, item.id)
    assert blocked_item.is_blocked

    html =
      view
      |> element("#launch-item-#{item.id} button[phx-click='toggle_blocked']")
      |> render_click()

    assert html =~ "Mark blocked"
    refute has_element?(view, "#blocked-work-view #blocked-launch-item-#{item.id}")

    assert {:ok, unblocked_item} = LaunchItems.get_company_launch_item(company.id, item.id)
    refute unblocked_item.is_blocked
  end

  test "shows validation errors when creation fails", %{conn: conn, owner_a: owner_a} do
    {:ok, view, _html} = live(conn, "/launch-items")

    html =
      render_submit(view, "create_launch_item", %{
        "launch_item" => %{
          "title" => " ",
          "owner_user_id" => owner_a.id,
          "status" => "planned"
        }
      })

    assert html =~ "can&#39;t be blank"
  end
end
