defmodule CymphoWeb.RuntimeControlControllerTest do
  use CymphoWeb.ConnCase, async: false

  alias Cympho.Agents
  alias Cympho.Agents.Agent
  alias Cympho.Companies
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.Issues
  alias Cympho.Issues.Issue
  alias Cympho.Repo

  test "owner stop pauses company and releases active work", %{conn: conn} do
    {conn, _user, company} =
      register_and_log_in_user(conn, %{role: "owner", is_board_member: true})

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, agent} =
      Agents.create_agent(%{
        name: "Runtime stop engineer",
        role: :engineer,
        status: :running,
        company_id: company.id
      })

    {:ok, issue} =
      Issues.create_issue(%{
        title: "Browser stop release issue",
        company_id: company.id,
        status: :in_progress,
        assignee_id: agent.id,
        checked_out_at: now,
        started_at: now
      })

    run =
      Repo.insert!(%Run{
        company_id: company.id,
        agent_id: agent.id,
        issue_id: issue.id,
        status: "running",
        adapter: "process",
        started_at: now,
        last_heartbeat_at: now
      })

    conn = post(conn, ~p"/runtime-control/stop", %{"return_to" => "/kanban"})

    assert redirected_to(conn) == "/kanban"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Runtime stopped"

    assert Companies.get_company!(company.id).status == "paused"

    reloaded_issue = Repo.get!(Issue, issue.id)
    assert reloaded_issue.status == :todo
    assert reloaded_issue.assignee_id == nil

    assert Repo.get!(Run, run.id).status == "cancelled"

    reloaded_agent = Repo.get!(Agent, agent.id)
    assert reloaded_agent.status == :paused
    assert reloaded_agent.governance_status == "paused"
  end

  test "member cannot pause runtime", %{conn: conn} do
    {conn, _user, company} = register_and_log_in_user(conn, %{role: "member"})

    conn = post(conn, ~p"/runtime-control/pause", %{"return_to" => "/kanban"})

    assert redirected_to(conn) == "/kanban"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Only owners"
    assert Companies.get_company!(company.id).status == "active"
  end

  test "owner can resume runtime", %{conn: conn} do
    {conn, _user, company} = register_and_log_in_user(conn, %{role: "owner"})
    {:ok, _paused} = Companies.pause_company(company, "setup")

    conn = post(conn, ~p"/runtime-control/resume", %{"return_to" => "/operations"})

    assert redirected_to(conn) == "/operations"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Runtime resumed."
    assert Companies.get_company!(company.id).status == "active"
  end
end
