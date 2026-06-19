defmodule CymphoWeb.RuntimeControlControllerTest do
  use CymphoWeb.ConnCase, async: false

  alias Cympho.AuditTrail
  alias Cympho.Agents
  alias Cympho.Agents.Agent
  alias Cympho.Companies
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.Issues
  alias Cympho.Issues.Issue
  alias Cympho.Repo
  alias Cympho.Wakes
  alias Cympho.Wakes.AgentWake

  test "owner stop pauses company and releases active work", %{conn: conn} do
    {conn, user, company} =
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

    assert Phoenix.Flash.get(conn.assigns.flash, :info) ==
             "Runtime stopped. Stopped 0 harness sessions, released 1 active issue, cancelled 1 run, and cancelled 0 queued wakes."

    assert Companies.get_company!(company.id).status == "paused"

    reloaded_issue = Repo.get!(Issue, issue.id)
    assert reloaded_issue.status == :todo
    assert reloaded_issue.assignee_id == nil

    assert Repo.get!(Run, run.id).status == "cancelled"

    reloaded_agent = Repo.get!(Agent, agent.id)
    assert reloaded_agent.status == :paused
    assert reloaded_agent.governance_status == "paused"

    {[event], 1} =
      AuditTrail.list_company_events(company.id, event_type: "company_runtime_stopped")

    assert event.actor_type == "user"
    assert event.actor_id == user.id
    assert event.resource_type == "company"
    assert event.resource_id == company.id
    assert event.payload["orchestrators_stopped"] == 0
    assert event.payload["issues_released"] == 1
    assert event.payload["runs_cancelled"] == 1
    assert event.payload["wakes_cancelled"] == 0
  end

  test "owner pause releases active work and preserves queued wakes", %{conn: conn} do
    {conn, user, company} =
      register_and_log_in_user(conn, %{role: "owner", is_board_member: true})

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, agent} =
      Agents.create_agent(%{
        name: "Runtime pause engineer",
        role: :engineer,
        status: :running,
        company_id: company.id
      })

    {:ok, active_issue} =
      Issues.create_issue(%{
        title: "Browser pause release issue",
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
        issue_id: active_issue.id,
        status: "running",
        adapter: "process",
        started_at: now,
        last_heartbeat_at: now
      })

    {:ok, queued_issue} =
      Issues.create_issue(%{
        title: "Queued wake preserved by pause",
        company_id: company.id,
        status: :todo,
        assignee_id: agent.id
      })

    {:ok, wake} =
      Wakes.do_wake_agent(agent.id, queued_issue.id, "manual_dispatch", "system", nil, %{
        "source" => "runtime-pause-controller-test"
      })

    conn = post(conn, ~p"/runtime-control/pause", %{"return_to" => "/operations"})

    assert redirected_to(conn) == "/operations"

    assert Phoenix.Flash.get(conn.assigns.flash, :info) ==
             "Runtime paused. Stopped 0 harness sessions, released 1 active issue, cancelled 1 run, and preserved queued wakes."

    assert Companies.get_company!(company.id).status == "paused"

    reloaded_issue = Repo.get!(Issue, active_issue.id)
    assert reloaded_issue.status == :todo
    assert reloaded_issue.assignee_id == nil

    assert Repo.get!(Run, run.id).status == "cancelled"
    assert Repo.get!(AgentWake, wake.id).status == "pending"

    {[event], 1} =
      AuditTrail.list_company_events(company.id, event_type: "company_runtime_paused")

    assert event.actor_id == user.id
    assert event.resource_type == "company"
    assert event.resource_id == company.id
    assert event.payload["issues_released"] == 1
    assert event.payload["runs_cancelled"] == 1
    assert event.payload["wakes_cancelled"] == 0
  end

  test "owner stop cancels queued wakes through the global control", %{conn: conn} do
    {conn, _user, company} =
      register_and_log_in_user(conn, %{role: "owner", is_board_member: true})

    {:ok, agent} =
      Agents.create_agent(%{
        name: "Runtime stop queued agent",
        role: :engineer,
        status: :idle,
        company_id: company.id
      })

    {:ok, issue} =
      Issues.create_issue(%{
        title: "Queued wake should not restart after stop",
        company_id: company.id,
        status: :todo,
        assignee_id: agent.id
      })

    {:ok, wake} =
      Wakes.do_wake_agent(agent.id, issue.id, "manual_dispatch", "system", nil, %{
        "source" => "runtime-control-test"
      })

    conn = post(conn, ~p"/runtime-control/stop", %{"return_to" => "/operations"})

    assert redirected_to(conn) == "/operations"

    assert Phoenix.Flash.get(conn.assigns.flash, :info) ==
             "Runtime stopped. Stopped 0 harness sessions, released 0 active issues, cancelled 0 runs, and cancelled 1 queued wake."

    assert Companies.get_company!(company.id).status == "paused"

    reloaded_wake = Repo.get!(AgentWake, wake.id)
    assert reloaded_wake.status == "cancelled"
    assert reloaded_wake.last_error == "Stopped from global runtime controls"
  end

  test "owner can switch runtime to low power", %{conn: conn} do
    {conn, user, company} = register_and_log_in_user(conn, %{role: "owner"})

    conn = post(conn, ~p"/runtime-control/low-power", %{"return_to" => "/dashboard"})

    assert redirected_to(conn) == "/dashboard"

    assert Phoenix.Flash.get(conn.assigns.flash, :info) ==
             "Runtime set to low power. Only high and critical queued work will auto-dispatch."

    reloaded = Companies.get_company!(company.id)
    assert reloaded.status == "active"
    assert Companies.low_power?(reloaded)

    {[event], 1} =
      AuditTrail.list_company_events(company.id, event_type: "company_runtime_low_power")

    assert event.actor_id == user.id
    assert event.resource_type == "company"
    assert event.resource_id == company.id
    assert event.payload == %{"action" => "low_power"}
  end

  test "member cannot pause runtime", %{conn: conn} do
    {conn, _user, company} = register_and_log_in_user(conn, %{role: "member"})

    conn = post(conn, ~p"/runtime-control/pause", %{"return_to" => "/kanban"})

    assert redirected_to(conn) == "/kanban"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Only owners"
    assert Companies.get_company!(company.id).status == "active"
  end

  test "owner can resume runtime", %{conn: conn} do
    {conn, user, company} = register_and_log_in_user(conn, %{role: "owner"})
    {:ok, _paused} = Companies.pause_company(company, "setup")

    conn = post(conn, ~p"/runtime-control/resume", %{"return_to" => "/operations"})

    assert redirected_to(conn) == "/operations"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Runtime resumed."
    assert Companies.get_company!(company.id).status == "active"

    {[event], 1} =
      AuditTrail.list_company_events(company.id, event_type: "company_runtime_resumed")

    assert event.actor_id == user.id
    assert event.resource_type == "company"
    assert event.resource_id == company.id
    assert event.payload == %{"action" => "resume"}
  end
end
