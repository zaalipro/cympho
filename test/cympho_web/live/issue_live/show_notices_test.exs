defmodule CymphoWeb.IssueLive.ShowNoticesTest do
  @moduledoc """
  The task page's live notices ("New comment added", "Issue updated by another
  user") are for what someone else did: the owner's own action on the page does
  not tell them about itself (smoke B8).
  """
  use CymphoWeb.LiveCase, async: true

  import Phoenix.LiveViewTest

  alias Cympho.{Comments, Issues, R3Fixtures}

  @comment "New comment added"
  @updated "Issue updated by another user"

  setup do
    nw = R3Fixtures.northwind!()
    %{nw: nw, conn: session_conn(nw.user, nw.company)}
  end

  # The page open and idle: its mount's own read-state broadcast is handled.
  defp open(conn, nw, key) do
    {:ok, view, _html} = live(conn, "/issues/#{nw.issues[key].id}")
    settle(view)
    {:ok, view}
  end

  # A broadcast sent before this call is already in the page's mailbox; render/1
  # pings the page, so it has handled it and every toast it pushed has reached the test.
  defp settle(view), do: render(view)

  defp session_conn(user, company) do
    Phoenix.ConnTest.build_conn()
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session("user_id", user.id)
    |> Plug.Conn.put_session("company_id", company.id)
  end

  describe "the owner's own action" do
    test "answering a question pushes no notice about it", %{conn: conn, nw: nw} do
      {:ok, view} = open(conn, nw, "NW-6")

      view
      |> form(".next form.ink", %{
        "_id" => nw.questions["Q1"].id,
        "response" => "Email the customer first"
      })
      |> render_submit()

      settle(view)
      refute_push_event(view, "toast", %{message: @comment})
      refute_push_event(view, "toast", %{message: @updated})
    end

    test "an own reply pushes no notice about it", %{conn: conn, nw: nw} do
      {:ok, view} = open(conn, nw, "NW-6")

      view
      |> form("form.composer", %{"comment" => %{"body" => "On it."}})
      |> render_submit()

      settle(view)
      refute_push_event(view, "toast", %{message: @comment})
      refute_push_event(view, "toast", %{message: @updated})
      assert render(view) =~ "On it."
    end
  end

  describe "someone else's change" do
    test "an agent's comment is still announced", %{conn: conn, nw: nw} do
      issue = nw.issues["NW-6"]
      {:ok, view} = open(conn, nw, "NW-6")

      {:ok, _comment} =
        Comments.create_comment(%{
          body: "Webhook handler is wired.",
          author_type: "agent",
          author_id: issue.assignee_id,
          issue_id: issue.id
        })

      html = settle(view)
      assert_push_event(view, "toast", %{message: @comment})
      assert html =~ "Webhook handler is wired."
    end

    test "a change made elsewhere is still announced", %{conn: conn, nw: nw} do
      issue = nw.issues["NW-6"]
      {:ok, view} = open(conn, nw, "NW-6")

      {:ok, _issue} = Issues.update_issue(Issues.get_issue!(issue.id), %{priority: :low})

      html = settle(view)
      assert_push_event(view, "toast", %{message: @updated})
      assert html =~ "Low"
    end
  end
end
