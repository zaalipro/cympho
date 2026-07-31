defmodule CymphoWeb.WorkModeControllerTest do
  use CymphoWeb.ConnCase, async: true

  import Ecto.Query

  alias Cympho.{Companies, Issues, Repo}
  alias Cympho.Issues.Issue

  setup %{conn: conn} do
    {conn, _user, company} = register_and_log_in_user(conn)
    %{conn: conn, company: company}
  end

  test "issue API creates and shows the selected work mode", %{conn: conn} do
    conn =
      post(conn, "/api/issues", %{
        "issue" => %{
          "title" => "Plan through the API",
          "work_mode" => "planning"
        }
      })

    assert %{"data" => %{"id" => issue_id, "work_mode" => "planning"}} =
             json_response(conn, 201)

    show_conn = get(recycle(conn), "/api/issues/#{issue_id}")

    assert %{"data" => %{"id" => ^issue_id, "work_mode" => "planning"}} =
             json_response(show_conn, 200)
  end

  test "issue API rejects an unsupported work mode", %{conn: conn} do
    conn =
      post(conn, "/api/issues", %{
        "issue" => %{
          "title" => "Unsafe API mode",
          "work_mode" => "unrestricted"
        }
      })

    assert %{"errors" => errors} = json_response(conn, 422)
    assert inspect(errors) =~ "work_mode"
  end

  test "issue API does not reveal another company's mode", %{conn: conn} do
    unique = System.unique_integer([:positive])

    {:ok, other_company} =
      Companies.create_company(%{
        name: "Other work mode #{unique}",
        slug: "other-work-mode-#{unique}"
      })

    {:ok, other_issue} =
      Issues.create_issue(%{
        company_id: other_company.id,
        title: "Private question-first issue",
        work_mode: :ask
      })

    conn = get(conn, "/api/issues/#{other_issue.id}")
    assert json_response(conn, 404)
  end

  test "quick create persists ask mode", %{conn: conn} do
    title = "Quick question-first #{System.unique_integer([:positive])}"

    conn =
      post(conn, "/issues/quick-create", %{
        "title" => title,
        "work_mode" => "ask"
      })

    issue = Repo.one!(from i in Issue, where: i.title == ^title)
    assert redirected_to(conn) == "/issues/#{issue.id}"
    assert issue.work_mode == :ask
  end

  test "quick create rejects an unsupported mode without creating an issue", %{conn: conn} do
    title = "Rejected quick mode #{System.unique_integer([:positive])}"

    conn =
      post(conn, "/issues/quick-create", %{
        "title" => title,
        "work_mode" => "do-everything"
      })

    assert redirected_to(conn) == "/issues"

    assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
             "Choose how the team should begin."

    refute Repo.exists?(from i in Issue, where: i.title == ^title)
  end
end
