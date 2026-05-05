defmodule CymphoWeb.TenancyTest do
  @moduledoc """
  Regression net for cross-tenant data leakage in LiveView mounts.

  Each test creates a record in company B, then mounts a LiveView as a user
  who only belongs to company A. The LiveView must redirect away (typically
  to the index page for that resource) — never render the cross-company
  record's data.

  When adding a new LiveView that loads a record by ID, add a case here.
  """

  use CymphoWeb.LiveCase, async: true

  import Phoenix.LiveViewTest

  alias Cympho.{Companies, Repo, Projects, Skills, Plugins, Budgets}
  alias Cympho.Users.User

  setup do
    {:ok, company_a} =
      Companies.create_company(%{
        name: "Company A",
        slug: "company-a-#{System.unique_integer([:positive])}"
      })

    {:ok, company_b} =
      Companies.create_company(%{
        name: "Company B",
        slug: "company-b-#{System.unique_integer([:positive])}"
      })

    {:ok, user_a} =
      %User{}
      |> User.registration_changeset(%{
        email: "user_a-#{System.unique_integer([:positive])}@example.com",
        name: "User A",
        password: "password123",
        company_id: company_a.id
      })
      |> Repo.insert()

    Companies.create_membership!(%{
      user_id: user_a.id,
      company_id: company_a.id,
      role: "member"
    })

    conn =
      build_conn()
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session("user_id", user_a.id)
      |> Plug.Conn.put_session("company_id", company_a.id)

    %{conn: conn, company_a: company_a, company_b: company_b, user_a: user_a}
  end

  describe "ProjectLive.Show" do
    test "redirects when project belongs to another company", %{
      conn: conn,
      company_b: company_b
    } do
      {:ok, project} =
        Projects.create_project(%{
          name: "B's secret project",
          prefix: "BSEC#{<<Enum.random(?A..?Z)>>}",
          company_id: company_b.id
        })

      assert {:error, {:live_redirect, %{to: "/projects"}}} =
               live(conn, "/projects/#{project.id}")
    end
  end

  describe "BudgetLive.Show" do
    test "redirects when budget belongs to another company", %{
      conn: conn,
      company_b: company_b
    } do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, budget} =
        Budgets.create_budget(%{
          name: "B's budget",
          scope_type: "company",
          scope_id: company_b.id,
          limit_amount: Decimal.new(1000),
          period_start: now,
          period_end: DateTime.add(now, 30 * 24 * 3600, :second),
          status: "active",
          company_id: company_b.id
        })

      # Live.BoardAuth catches this first when no board members exist (redirects
      # to "/"), otherwise BudgetLive.Show's tenancy check redirects to "/budgets".
      # Either is a valid denial — what matters is no render of B's data.
      result = live(conn, "/budgets/#{budget.id}")

      assert match?({:error, {:live_redirect, %{to: "/budgets"}}}, result) or
               match?({:error, {:redirect, %{to: "/"}}}, result),
             "expected a redirect away from cross-tenant budget, got: #{inspect(result)}"
    end
  end

  describe "SkillLive.Show" do
    test "redirects when skill belongs to another company", %{
      conn: conn,
      company_b: company_b
    } do
      {:ok, skill} =
        Skills.create_skill(%{
          name: "B's skill",
          identifier: "b-skill-#{System.unique_integer([:positive])}",
          manifest: %{},
          company_id: company_b.id
        })

      assert {:error, {:live_redirect, %{to: "/skills"}}} = live(conn, "/skills/#{skill.id}")
    end
  end

  describe "PluginLive.Show" do
    test "redirects when plugin belongs to another company", %{
      conn: conn,
      company_b: company_b
    } do
      {:ok, plugin} =
        Plugins.create_plugin(%{
          name: "B's plugin",
          identifier: "b-plugin-#{System.unique_integer([:positive])}",
          version: "1.0.0",
          manifest: %{},
          company_id: company_b.id
        })

      assert {:error, {:live_redirect, %{to: "/plugins"}}} =
               live(conn, "/plugins/#{plugin.id}")
    end
  end

  describe "guest user (no session)" do
    test "user_companies is empty (no cross-tenant enumeration)", %{
      company_a: _a,
      company_b: _b
    } do
      conn = build_conn() |> Plug.Test.init_test_session(%{})

      {:ok, view, _html} = live(conn, "/issues")

      assert live_assigns(view).user_companies == []
      assert live_assigns(view).current_company == nil
    end
  end

  defp live_assigns(view) do
    :sys.get_state(view.pid).socket.assigns
  end
end
