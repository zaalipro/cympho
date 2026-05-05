defmodule Cympho.WorkProductsTest do
  use Cympho.DataCase, async: true

  alias Cympho.WorkProducts
  alias Cympho.WorkProducts.IssueWorkProduct
  alias Cympho.Issues
  alias Cympho.Activities

  setup do
    {:ok, issue} =
      Issues.create_issue(%{
        title: "Test Issue",
        description: "Test description",
        status: :backlog,
        priority: :medium
      })

    %{issue: issue}
  end

  describe "create_work_product/1" do
    test "creates a work product with valid attrs", %{issue: issue} do
      attrs = %{
        issue_id: issue.id,
        kind: "code_change",
        title: "Implemented auth module",
        description: "Added JWT-based authentication",
        payload: %{"files_changed" => ["lib/auth.ex", "test/auth_test.exs"]},
        url: "https://github.com/org/repo/pull/42"
      }

      assert {:ok, %IssueWorkProduct{} = wp} = WorkProducts.create_work_product(attrs)
      assert wp.issue_id == issue.id
      assert wp.kind == "code_change"
      assert wp.title == "Implemented auth module"
      assert wp.description == "Added JWT-based authentication"
      assert wp.payload["files_changed"] == ["lib/auth.ex", "test/auth_test.exs"]
      assert wp.url == "https://github.com/org/repo/pull/42"
    end

    test "creates a work product with minimal attrs", %{issue: issue} do
      attrs = %{
        issue_id: issue.id,
        kind: "document",
        title: "API Documentation"
      }

      assert {:ok, %IssueWorkProduct{} = wp} = WorkProducts.create_work_product(attrs)
      assert wp.issue_id == issue.id
      assert wp.kind == "document"
      assert wp.payload == %{}
      assert wp.metadata == %{}
    end

    test "returns error with missing required fields", %{issue: issue} do
      attrs = %{issue_id: issue.id}
      assert {:error, changeset} = WorkProducts.create_work_product(attrs)
      errors = errors_on(changeset)
      assert errors[:kind]
      assert errors[:title]
    end

    test "returns error with invalid kind", %{issue: issue} do
      attrs = %{
        issue_id: issue.id,
        kind: "invalid_kind",
        title: "Test"
      }

      assert {:error, changeset} = WorkProducts.create_work_product(attrs)
      assert errors_on(changeset)[:kind]
    end

    test "returns error with non-existent issue_id" do
      attrs = %{
        issue_id: "00000000-0000-0000-0000-000000000000",
        kind: "code_change",
        title: "Test"
      }

      assert {:error, changeset} = WorkProducts.create_work_product(attrs)
      assert errors_on(changeset)[:issue_id]
    end

    test "accepts all valid kinds", %{issue: issue} do
      for kind <- ~w(code_change document url artifact other) do
        attrs = %{issue_id: issue.id, kind: kind, title: "WP for #{kind}"}
        assert {:ok, %IssueWorkProduct{}} = WorkProducts.create_work_product(attrs)
      end
    end
  end

  describe "activity integration" do
    test "creating a work product logs work_product_created activity", %{issue: issue} do
      attrs = %{
        issue_id: issue.id,
        kind: "code_change",
        title: "Implemented feature",
        created_by_agent_id: nil
      }

      {:ok, wp} = WorkProducts.create_work_product(attrs)

      activities = Activities.list_activities(issue.id)
      wp_activity = Enum.find(activities, &(&1.action == "work_product_created"))
      assert wp_activity != nil
      assert wp_activity.metadata["work_product_id"] == wp.id
      assert wp_activity.metadata["kind"] == "code_change"
      assert wp_activity.metadata["title"] == "Implemented feature"
    end
  end

  describe "list_work_products/1" do
    test "returns work products for an issue", %{issue: issue} do
      for kind <- ~w(code_change document url) do
        WorkProducts.create_work_product(%{
          issue_id: issue.id,
          kind: kind,
          title: "WP #{kind}"
        })
      end

      wps = WorkProducts.list_work_products(issue.id)
      assert length(wps) == 3
      kinds = Enum.map(wps, & &1.kind) |> Enum.sort()
      assert kinds == ~w(code_change document url)
    end

    test "returns empty list for issue with no work products" do
      wps = WorkProducts.list_work_products("00000000-0000-0000-0000-000000000000")
      assert wps == []
    end
  end

  describe "get_work_product/1 and get_work_product!/1" do
    test "get_work_product returns {:ok, work_product}", %{issue: issue} do
      {:ok, wp} =
        WorkProducts.create_work_product(%{
          issue_id: issue.id,
          kind: "document",
          title: "Test doc"
        })

      assert {:ok, found} = WorkProducts.get_work_product(wp.id)
      assert found.id == wp.id
    end

    test "get_work_product returns {:error, :not_found} for missing id" do
      assert {:error, :not_found} =
               WorkProducts.get_work_product("00000000-0000-0000-0000-000000000000")
    end

    test "get_work_product! raises for non-existent id" do
      assert_raise Ecto.NoResultsError, fn ->
        WorkProducts.get_work_product!("00000000-0000-0000-0000-000000000000")
      end
    end
  end

  describe "update_work_product/2" do
    test "updates a work product", %{issue: issue} do
      {:ok, wp} =
        WorkProducts.create_work_product(%{
          issue_id: issue.id,
          kind: "document",
          title: "Original"
        })

      assert {:ok, updated} = WorkProducts.update_work_product(wp, %{title: "Updated"})
      assert updated.title == "Updated"
    end
  end

  describe "delete_work_product/1" do
    test "deletes a work product", %{issue: issue} do
      {:ok, wp} =
        WorkProducts.create_work_product(%{
          issue_id: issue.id,
          kind: "document",
          title: "To delete"
        })

      assert :ok = WorkProducts.delete_work_product(wp)
      assert {:error, :not_found} = WorkProducts.get_work_product(wp.id)
    end
  end
end
