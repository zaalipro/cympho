defmodule CymphoWeb.IssueLive.ShowNoticesTest do
  @moduledoc """
  The task page's live notices ("New comment added", "Issue updated by another
  user") are for what someone else did: the owner's own action on the page does
  not tell them about itself (smoke B8).
  """
  use CymphoWeb.LiveCase, async: true

  import Phoenix.LiveViewTest

  alias Cympho.{Comments, Issues, R3Fixtures, Repo}
  alias Cympho.Issues.Issue

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

    test "the same owner's change in another tab pushes no notice there", %{conn: conn, nw: nw} do
      {:ok, first} = open(conn, nw, "NW-6")
      {:ok, second} = open(conn, nw, "NW-6")

      render_hook(second, "combobox_priority", %{"selected" => "low"})

      html = settle(first)
      refute_push_event(first, "toast", %{message: @updated})
      assert html =~ "Low"
    end

    test "an answer sent from the Inbox pushes no notice on the open task", %{conn: conn, nw: nw} do
      {:ok, task} = open(conn, nw, "NW-6")
      {:ok, inbox, _html} = live(conn, "/inbox?kind=question")

      inbox
      |> form("#ns-answer", %{"response" => "Email the customer first"})
      |> render_submit()

      html = settle(task)
      refute_push_event(task, "toast", %{message: @comment})
      refute_push_event(task, "toast", %{message: @updated})
      assert html =~ "Email the customer first"
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

    test "another signed-in user's change is still announced", %{conn: conn, nw: nw} do
      issue = nw.issues["NW-6"]
      {:ok, view} = open(conn, nw, "NW-6")

      Issues.put_actor_user_id(Ecto.UUID.generate())
      {:ok, _issue} = Issues.update_issue(Issues.get_issue!(issue.id), %{priority: :low})

      settle(view)
      assert_push_event(view, "toast", %{message: @updated})
    end

    test "a change the page already shows when its broadcast arrives is still announced", %{
      conn: conn,
      nw: nw
    } do
      issue = nw.issues["NW-6"]
      {:ok, view} = open(conn, nw, "NW-6")

      # Someone else's write lands; its broadcast follows a moment later.
      {:ok, changed} =
        Issues.get_issue!(issue.id)
        |> Issue.changeset(%{priority: :low})
        |> Ecto.Changeset.optimistic_lock(:lock_version)
        |> Repo.update()

      # Meanwhile the page reloads the task for the owner's own reply.
      view
      |> form("form.composer", %{"comment" => %{"body" => "On it."}})
      |> render_submit()

      settle(view)
      refute_push_event(view, "toast", %{message: @updated})

      Phoenix.PubSub.broadcast(
        Cympho.PubSub,
        "company:#{nw.company.id}:issues",
        {:issue_updated, changed}
      )

      settle(view)
      assert_push_event(view, "toast", %{message: @updated})
    end
  end
end
