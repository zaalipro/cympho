defmodule CymphoWeb.UserAuthTest do
  use CymphoWeb.LiveCase, async: true

  import Phoenix.LiveViewTest
  import Phoenix.ConnTest

  alias Cympho.{Agents, Approvals, BoardApprovals, Companies, Inbox, Issues, Repo}
  alias Cympho.Finances.{BudgetIncident, BudgetPolicy}
  alias Cympho.Users.User

  setup do
    # Create test companies
    {:ok, company1} =
      Companies.create_company(%{
        name: "Test Company 1",
        slug: "test-company-1",
        logo_url: "https://example.com/logo1.png"
      })

    {:ok, company2} =
      Companies.create_company(%{
        name: "Test Company 2",
        slug: "test-company-2",
        logo_url: "https://example.com/logo2.png"
      })

    # Create test user with password
    {:ok, user} =
      %User{}
      |> User.registration_changeset(%{
        email: "test@example.com",
        name: "Test User",
        password: "password123",
        company_id: company1.id
      })
      |> Repo.insert()

    # Add user to both companies. Backdate the first membership so
    # second-precision inserted_at ordering is deterministic without sleeping.
    m1 =
      Companies.create_membership!(%{user_id: user.id, company_id: company1.id, role: "member"})

    earlier = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(-60)
    {:ok, _} = Repo.update(Ecto.Changeset.change(m1, inserted_at: earlier))
    Companies.create_membership!(%{user_id: user.id, company_id: company2.id, role: "admin"})

    %{user: user, company1: company1, company2: company2}
  end

  describe "on_mount/4" do
    test "assigns current_user from session", %{user: user} do
      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session("user_id", user.id)

      {:ok, view, _html} = live(conn, "/issues")

      assert live_assigns(view).current_user.id == user.id
    end

    test "redirects guests to login" do
      conn = build_conn() |> Plug.Test.init_test_session(%{})

      assert_redirected_to_login(conn)
    end

    test "redirects sessions with invalid user_id to login" do
      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session("user_id", "00000000-0000-0000-0000-000000000000")

      assert_redirected_to_login(conn)
    end

    test "loads user_companies for authenticated user", %{user: user} do
      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session("user_id", user.id)

      {:ok, view, _html} = live(conn, "/issues")

      assert length(live_assigns(view).user_companies) == 2
    end

    test "guest user cannot inspect company lists", %{
      company1: _company1,
      company2: _company2
    } do
      conn = build_conn() |> Plug.Test.init_test_session(%{})

      assert_redirected_to_login(conn)
    end

    test "uses session company_id when valid", %{user: user, company2: company2} do
      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session("user_id", user.id)
        |> Plug.Conn.put_session("company_id", company2.id)

      {:ok, view, _html} = live(conn, "/issues")

      assert live_assigns(view).current_company.id == company2.id
    end

    test "falls back to user.company_id when session company_id is missing", %{
      user: user,
      company1: company1
    } do
      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session("user_id", user.id)

      {:ok, view, _html} = live(conn, "/issues")

      assert live_assigns(view).current_company.id == company1.id
    end

    test "falls back to first membership when session company_id is invalid", %{
      user: user,
      company1: company1
    } do
      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session("user_id", user.id)
        |> Plug.Conn.put_session("company_id", "00000000-0000-0000-0000-000000000000")

      {:ok, view, _html} = live(conn, "/issues")

      assert live_assigns(view).current_company.id == company1.id
    end

    test "falls back to first membership when user.company_id is not in memberships", %{
      user: user,
      company1: company1
    } do
      # Update user to point to a company they're not a member of
      user
      |> User.changeset(%{company_id: nil})
      |> Repo.update!()

      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session("user_id", user.id)

      {:ok, view, _html} = live(conn, "/issues")

      # Should fall back to first company in memberships
      assert live_assigns(view).current_company.id == company1.id
    end

    test "guest user cannot inspect current_company", %{company1: _company1} do
      conn = build_conn() |> Plug.Test.init_test_session(%{})

      assert_redirected_to_login(conn)
    end

    test "redirects membership-less users into onboarding" do
      # Create a user with no company memberships; the require_company gate
      # sends them to the onboarding wizard instead of mounting the app.
      {:ok, lonely_user} =
        %User{}
        |> User.registration_changeset(%{
          email: "lonely@example.com",
          name: "Lonely User",
          password: "password123",
          company_id: nil
        })
        |> Repo.insert()

      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session("user_id", lonely_user.id)

      assert {:error, {:redirect, %{to: "/onboarding"}}} = live(conn, "/issues")
    end

    test "prioritizes session company_id over user.company_id", %{
      user: user,
      company2: company2
    } do
      # User's default is company1, but session specifies company2
      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session("user_id", user.id)
        |> Plug.Conn.put_session("company_id", company2.id)

      {:ok, view, _html} = live(conn, "/issues")

      # Should use company2 from session, not user's default
      assert live_assigns(view).current_company.id == company2.id
    end
  end

  describe "integration with LiveViews" do
    test "current_user is accessible in LiveView assigns", %{user: user} do
      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session("user_id", user.id)

      {:ok, view, _html} = live(conn, "/issues")

      assert live_assigns(view).current_user.id == user.id
    end

    test "current_company is accessible in LiveView assigns", %{
      user: user,
      company1: company1
    } do
      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session("user_id", user.id)

      {:ok, view, _html} = live(conn, "/issues")

      assert live_assigns(view).current_company.id == company1.id
    end

    test "user_companies is accessible in LiveView assigns", %{user: user} do
      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session("user_id", user.id)

      {:ok, view, _html} = live(conn, "/issues")

      assert length(live_assigns(view).user_companies) == 2
    end

    test "sidebar exposes pending approval work with a badge", %{
      user: user,
      company1: company
    } do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Approval Badge Agent",
          role: :ceo,
          company_id: company.id
        })

      {:ok, _approval} =
        Approvals.create_approval(%{
          type: "launch_gate",
          requested_by_agent_id: agent.id
        })

      {:ok, _board_approval} =
        BoardApprovals.create_board_approval(%{
          title: "Hire runtime owner",
          category: "agent_hire",
          company_id: company.id
        })

      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session("user_id", user.id)

      {:ok, view, html} = live(conn, "/issues")

      assert live_assigns(view).nav_approval_count == 2
      assert live_assigns(view).nav_inbox_count == 2
      assert live_assigns(view).inbox_badge_count == 2
      assert html =~ ~s(href="/approvals?status=pending")
      assert html =~ ~s(data-testid="nav-badge-approvals")
      assert html =~ ~r/<span[^>]*data-testid="nav-badge-approvals"[^>]*>\s*2\s*<\/span>/s
      assert html =~ ~r/<span[^>]*data-testid="nav-badge-inbox"[^>]*>\s*2\s*<\/span>/s

      assert html =~
               ~r/<span[^>]*data-testid="mobile-nav-badge-inbox"[^>]*>\s*2\s*<\/span>/s
    end

    test "resolving an approval refreshes both Inbox badges", %{
      user: user,
      company1: company
    } do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Approval Refresh Agent",
          role: :ceo,
          company_id: company.id
        })

      {:ok, approval} =
        Approvals.create_approval(%{
          type: "launch_gate",
          requested_by_agent_id: agent.id
        })

      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session("user_id", user.id)

      {:ok, view, _html} = live(conn, "/issues")
      assert live_assigns(view).nav_inbox_count == 1
      assert live_assigns(view).inbox_badge_count == 1

      assert {:ok, _resolved} =
               Approvals.resolve_approval(approval.id, :approved, %{
                 resolved_by_user_id: user.id,
                 resolution_reason: "Approved in test"
               })

      wait_until(fn ->
        render(view)
        assert live_assigns(view).nav_inbox_count == 0
        assert live_assigns(view).inbox_badge_count == 0
      end)
    end

    test "Inbox badges count deduplicated current-company budget incidents", %{
      user: user,
      company1: company,
      company2: other_company
    } do
      policy = insert_budget_policy!(company)
      _warning = insert_budget_incident!(policy, "warning")
      _exceeded = insert_budget_incident!(policy, "budget_exceeded")

      other_policy = insert_budget_policy!(other_company)
      _foreign_incident = insert_budget_incident!(other_policy, "warning")

      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session("user_id", user.id)
        |> Plug.Conn.put_session("company_id", company.id)

      {:ok, view, html} = live(conn, "/issues")

      assert live_assigns(view).nav_inbox_count == 1
      assert live_assigns(view).inbox_badge_count == 1
      assert html =~ ~r/<span[^>]*data-testid="nav-badge-inbox"[^>]*>\s*1\s*<\/span>/s

      assert html =~
               ~r/<span[^>]*data-testid="mobile-nav-badge-inbox"[^>]*>\s*1\s*<\/span>/s
    end

    test "Inbox badge does not double-count an unread blocked issue", %{
      user: user,
      company1: company
    } do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Deduplicated Badge Agent",
          role: :engineer,
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "One blocked owner item",
          status: :blocked,
          company_id: company.id,
          assignee_id: agent.id
        })

      assert {:ok, _entry} = Inbox.ensure_inbox_entry(issue.id, agent.id)

      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session("user_id", user.id)
        |> Plug.Conn.put_session("company_id", company.id)

      {:ok, view, html} = live(conn, "/issues")

      assert live_assigns(view).nav_inbox_count == 1
      assert live_assigns(view).inbox_badge_count == 1
      assert html =~ ~r/<span[^>]*data-testid="nav-badge-inbox"[^>]*>\s*1\s*<\/span>/s
    end

    test "final_review_required wake bumps inbox badge without reload", %{
      user: user,
      company1: company
    } do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Review Notify Agent",
          role: :engineer,
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Needs final review",
          status: :in_review,
          company_id: company.id,
          assignee_id: agent.id
        })

      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session("user_id", user.id)
        |> Plug.Conn.put_session("company_id", company.id)

      {:ok, view, _html} = live(conn, "/issues")
      assert live_assigns(view).inbox_badge_count == 0

      assert {:ok, _wake} =
               Cympho.Wakes.do_wake_agent(
                 agent.id,
                 issue.id,
                 "final_review_required",
                 "system",
                 "test",
                 %{}
               )

      wait_until(fn ->
        render(view)
        assert live_assigns(view).nav_inbox_count == 1
        assert live_assigns(view).inbox_badge_count == 1
      end)

      assert Cympho.OwnerAttention.unresolved_count(company.id, user) == 1
    end

    test "pure agent unreads do not inflate the Needs you badge", %{
      user: user,
      company1: company
    } do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Unread Only Agent",
          role: :engineer,
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Unread noise",
          status: :todo,
          company_id: company.id,
          assignee_id: agent.id
        })

      assert {:ok, _entry} = Inbox.ensure_inbox_entry(issue.id, agent.id)

      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session("user_id", user.id)
        |> Plug.Conn.put_session("company_id", company.id)

      {:ok, view, html} = live(conn, "/issues")

      assert live_assigns(view).nav_inbox_count == 0
      assert live_assigns(view).inbox_badge_count == 0
      refute html =~ ~s(data-testid="nav-badge-inbox")
    end
  end

  defp live_assigns(view) do
    :sys.get_state(view.pid).socket.assigns
  end

  defp assert_redirected_to_login(conn) do
    assert {:error, {:redirect, %{to: "/login?return_to=%2Fissues"}}} =
             live(conn, "/issues")
  end

  defp insert_budget_policy!(company) do
    %BudgetPolicy{}
    |> BudgetPolicy.changeset(%{
      company_id: company.id,
      scope: "company",
      period: "monthly",
      budget_limit_usd: "100",
      warning_threshold_pct: "80",
      action_on_exceed: "warn"
    })
    |> Repo.insert!()
  end

  defp insert_budget_incident!(policy, event_type) do
    %BudgetIncident{}
    |> BudgetIncident.changeset(%{
      budget_policy_id: policy.id,
      company_id: policy.company_id,
      event_type: event_type,
      spend_usd: "100",
      budget_limit_usd: policy.budget_limit_usd,
      threshold_pct: "100"
    })
    |> Repo.insert!()
  end
end
