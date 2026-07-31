defmodule CymphoWeb.SimpleModeCopyTest do
  @moduledoc """
  Simple mode is a CSS layer, not a server-side branch: `data-ui-mode` is set
  client-side, so both the advanced and the simple wording render into the same
  markup and CSS shows one of them.

  That makes a whole class of regression invisible to the other suites — delete
  a `.ui-simple-only` span and advanced-mode assertions still pass while simple
  mode silently falls back to operator jargon. These tests pin both halves of
  each pair so dropping either side fails loudly.
  """
  use CymphoWeb.LiveCase, async: true

  alias Cympho.Projects
  alias CymphoWeb.ConnCase

  describe "paired copy" do
    test "budgets empty state carries both the operator and the plain wording" do
      {conn, _company} = board_conn()

      {:ok, _view, html} = live(conn, "/budgets")

      # "Guardrail" is gone from this page; both halves now say "limit", but the
      # advanced half still explains the hard stop and the simple half does not.
      refute html =~ "guardrails yet"
      assert html =~ "No spending limits yet"
      assert html =~ "No spending limit yet"
      assert html =~ "provider spend has a hard stop"
      assert html =~ "Set one so the team can&#39;t overspend."
      assert html =~ "Spending limits"
      assert html =~ "Limits"
    end

    test "costs states both the operator and the plain wording", %{conn: conn} do
      {conn, _user, _company} = ConnCase.register_and_log_in_user(conn)

      {:ok, _view, html} = live(conn, "/costs")

      # Cost command summary.
      assert html =~ "No spend has landed yet, but a budget cap makes launch decisions safer"
      assert html =~ "No spending limit is set yet."
      # Breakdown empty state.
      assert html =~ "Set a spending limit before launching more runtime"
      assert html =~ "Costs appear here once agents start running."
    end

    test "a project without a repo names it both ways", %{conn: conn} do
      {conn, _user, company} = ConnCase.register_and_log_in_user(conn)

      {:ok, _project} =
        Projects.create_project(%{
          name: "No Repo Project",
          prefix: "NRP",
          company_id: company.id
        })

      {:ok, _view, html} = live(conn, "/projects")

      assert html =~ "No repository configured"
      assert html =~ "No code repo yet"
    end
  end

  describe "mode gating" do
    test "board gates its filter bar and view toggles to advanced only", %{conn: conn} do
      {conn, _user, _company} = ConnCase.register_and_log_in_user(conn)

      {:ok, _view, html} = live(conn, "/kanban")

      # Both clusters must carry the gate class; without it simple mode shows
      # the full re-slicing toolbar again.
      assert html =~ "ui-advanced-only cympho-panel"
      assert html =~ ~r/data-testid="kanban-view-controls"[^>]*ui-advanced-only/s
    end

    test "inbox keeps Needs you visible and gates the other lanes", %{conn: conn} do
      {conn, _user, _company} = ConnCase.register_and_log_in_user(conn)

      {:ok, _view, html} = live(conn, "/inbox")

      assert html =~ "Needs you"
      # The advanced lanes still render, gated rather than removed.
      assert html =~ "Awaiting review"
      assert html =~ "Needs my action"
    end
  end

  describe "priority renders as a word and an arrow" do
    test "issue rows carry both the pill and the arrow", %{conn: conn} do
      {conn, _user, company} = ConnCase.register_and_log_in_user(conn)

      {:ok, project} =
        Projects.create_project(%{name: "Arrow Project", prefix: "ARW", company_id: company.id})

      for {title, priority} <- [{"Urgent thing", :critical}, {"Big thing", :high}] do
        {:ok, _issue} =
          Cympho.Issues.create_issue(%{
            title: title,
            priority: priority,
            company_id: company.id,
            project_id: project.id
          })
      end

      {:ok, _view, html} = live(conn, "/issues?density=detailed")

      # Advanced keeps the word...
      assert html =~ "High"
      assert html =~ "Critical"
      # ...simple gets a directional arrow with the word as its accessible name.
      assert html =~ "hero-chevron-up-mini"
      assert html =~ "hero-chevron-double-up-mini"
      assert html =~ ~s(aria-label="High priority")
      assert html =~ ~s(aria-label="Critical priority")
    end
  end

  describe "simple-mode home destinations stay reachable" do
    test "runtime failures section is not advanced-only", %{conn: conn} do
      {conn, _user, _company} = ConnCase.register_and_log_in_user(conn)

      {:ok, _view, html} = live(conn, "/operations")

      # Home's "Something went wrong" card deep-links to #runtime-failures in
      # simple mode. If this section becomes advanced-only that flow dead-ends.
      assert html =~ ~s(id="runtime-failures")
      refute html =~ ~r/id="runtime-failures"\s+class="ui-advanced-only/s
      assert html =~ "What went wrong"
      assert html =~ "Recent Runtime Failures"
    end
  end

  defp board_conn do
    conn = authenticated_conn(%{is_board_member: true})
    {conn, current_company()}
  end
end
