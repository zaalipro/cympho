defmodule CymphoWeb.IssueLiveTest do
  use CymphoWeb.LiveCase, async: true

  import Phoenix.LiveViewTest

  alias Cympho.Issues
  alias Cympho.Comments

  setup do
    {:ok, issue} =
      Issues.create_issue(%{
        title: "Test Issue",
        description: "Test description for the issue",
        status: :open,
        priority: :high
      })

    %{issue: issue}
  end

  describe "Index - Issue List" do
    test "renders all issues", %{issue: issue} do
      {:ok, _view, html} = live(conn(), "/issues")

      assert html =~ "All Issues"
      assert html =~ issue.title
    end

    test "shows issue status badges", %{issue: issue} do
      {:ok, _view, html} = live(conn(), "/issues")

      assert html =~ "open"
      assert html =~ "high"
    end

    test "shows comment count", %{issue: issue} do
      {:ok, _view, html} = live(conn(), "/issues")

      assert html =~ "0 comments"
    end
  end

  describe "Show - Issue Detail" do
    test "renders issue detail", %{issue: issue} do
      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ issue.title
      assert html =~ issue.description
      assert html =~ "open"
      assert html =~ "high"
    end

    test "renders comments section", %{issue: issue} do
      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Comments"
      assert html =~ "Add Comment"
    end

    test "shows existing comments", %{issue: issue} do
      {:ok, _comment} =
        Comments.create_comment(%{
          body: "Test comment body",
          author: "Test Author",
          issue_id: issue.id
        })

      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Test comment body"
      assert html =~ "Test Author"
    end

    test "comment form accepts input", %{issue: issue} do
      {:ok, view, _html} = live(conn(), "/issues/#{issue.id}")

      form =
        form(view, "#comment-form", %{
          "comment" => %{
            "author" => "New Author",
            "body" => "New comment body"
          }
        })

      assert form
    end
  end
end
