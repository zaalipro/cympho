defmodule Cympho.Notifications.AlertEventsTest do
  @moduledoc """
  B6: the five alert events of Settings' "Tell me when…". The four new ones are
  opt-in, so nobody gets a surprise email; each is sent to the members of the
  company it happened in who chose it.
  """
  use Cympho.DataCase, async: false

  alias Cympho.{
    Agents,
    Companies,
    Finances,
    HeartbeatEngine,
    IssueThreadInteractions,
    Users,
    Wakes
  }

  alias Cympho.Finances.BudgetPolicy
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.Issues.Issue
  alias Cympho.Notifications.{Dispatcher, NotificationPreference}

  @new_events ~w(agent_question review_ready work_stopped spend_threshold)

  describe "event_allowed?/2" do
    test "the approval event is on by default and the four new events are off" do
      pref = %NotificationPreference{config: %{}}

      assert Dispatcher.event_allowed?(pref, "human_approval_required")
      for event <- @new_events, do: refute(Dispatcher.event_allowed?(pref, event))
    end

    test "a saved choice wins, and a message without an event is delivered" do
      pref = %NotificationPreference{
        config: %{"events" => %{"agent_question" => true, "human_approval_required" => false}}
      }

      assert Dispatcher.event_allowed?(pref, "agent_question")
      refute Dispatcher.event_allowed?(pref, "human_approval_required")
      refute Dispatcher.event_allowed?(pref, "review_ready")
      assert Dispatcher.event_allowed?(pref, nil)
      assert Dispatcher.event_allowed?(%NotificationPreference{config: nil}, "issue_assigned")
    end

    test "the default event config lists all five events, only the approval one on" do
      assert Users.default_event_config() == %{
               "human_approval_required" => true,
               "agent_question" => false,
               "review_ready" => false,
               "work_stopped" => false,
               "spend_threshold" => false
             }
    end
  end

  describe "emission" do
    setup do
      company = company!("alerts")
      chooser = member!(company, "chooser", Map.new(@new_events, &{&1, true}))
      quiet = member!(company, "quiet", nil)
      other = company!("elsewhere")
      outsider = member!(other, "outsider", Map.new(@new_events, &{&1, true}))
      agent = agent!(company, "Ravi")
      issue = issue!(company, agent, "AL-1", "Connect Stripe payments")

      %{
        company: company,
        chooser: chooser,
        quiet: quiet,
        outsider: outsider,
        agent: agent,
        issue: issue
      }
    end

    test "an agent's question emails the members who chose it", ctx do
      {:ok, _} =
        IssueThreadInteractions.create_interaction(%{
          issue_id: ctx.issue.id,
          kind: :ask_user_questions,
          created_by_agent_id: ctx.agent.id,
          payload: %{"questions" => [%{"question" => "Retry or email first?"}]}
        })

      assert_email(ctx.chooser, "Ravi asked you something")
      refute_email(ctx.quiet)
      refute_email(ctx.outsider)
    end

    test "work ready for review emails once per task", ctx do
      assert {:ok, _} = Wakes.wake_for_final_review(ctx.issue)
      assert_email(ctx.chooser, "AL-1 is ready for your review")

      assert {:ok, _} = Wakes.wake_for_final_review(ctx.issue)
      refute_email(ctx.chooser)
      refute_email(ctx.quiet)
      refute_email(ctx.outsider)
    end

    test "a failed run emails work stopped", ctx do
      run =
        Repo.insert!(%Run{
          company_id: ctx.company.id,
          agent_id: ctx.agent.id,
          issue_id: ctx.issue.id,
          status: "running",
          adapter: "process",
          started_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      assert {:ok, _} = HeartbeatEngine.fail_run(run, "Test database not reachable")

      assert_email(ctx.chooser, "A run on AL-1 failed")
      refute_email(ctx.quiet)
      refute_email(ctx.outsider)
    end

    test "a paused agent emails work stopped", ctx do
      assert {:ok, _} = Agents.pause_agent(ctx.agent, "3 failed attempts in a row on AL-1")

      assert_email(ctx.chooser, "Ravi was paused")
      refute_email(ctx.quiet)
      refute_email(ctx.outsider)
    end

    test "spending at the warning line and at the limit emails spend threshold", ctx do
      Repo.insert!(%BudgetPolicy{
        company_id: ctx.company.id,
        scope: "company",
        period: "monthly",
        budget_limit_usd: Decimal.new("100.00"),
        warning_threshold_pct: Decimal.new("80.0"),
        action_on_exceed: "warn",
        is_active: true
      })

      {:ok, _} = usage!(ctx.company, "85.00")
      assert_email(ctx.chooser, "Spending reached 85% of the limit")

      {:ok, _} = usage!(ctx.company, "20.00")
      assert_email(ctx.chooser, "Spending reached the limit")
      refute_email(ctx.quiet)
      refute_email(ctx.outsider)
    end
  end

  defp assert_email(user, subject) do
    address = user.email
    assert_receive {:email, %{to: [{_, ^address}], subject: ^subject}}, 2_000
  end

  defp refute_email(user) do
    address = user.email
    refute_receive {:email, %{to: [{_, ^address}]}}, 300
  end

  defp company!(label) do
    unique = System.unique_integer([:positive])

    {:ok, company} =
      Companies.create_company(%{name: "#{label} #{unique}", slug: "#{label}-#{unique}"})

    company
  end

  defp member!(company, label, events) do
    unique = System.unique_integer([:positive])

    {:ok, user} =
      Users.create_user(%{email: "#{label}-#{unique}@example.com", name: "#{label} #{unique}"})

    {:ok, _} =
      Companies.create_membership(%{user_id: user.id, company_id: company.id, role: "member"})

    prefs = Users.ensure_default_prefs(user.id)

    if events do
      email = Enum.find(prefs, &(&1.channel_type == "email"))
      {:ok, _} = Users.update_pref_events(email.id, events)
    end

    user
  end

  defp agent!(company, name) do
    {:ok, agent} =
      Agents.create_agent(%{
        company_id: company.id,
        name: name,
        role: :engineer,
        status: :idle,
        adapter: :process
      })

    agent
  end

  defp issue!(company, agent, identifier, title) do
    Repo.insert!(%Issue{
      company_id: company.id,
      identifier: identifier,
      title: title,
      status: :in_progress,
      priority: :high,
      assignee_id: agent.id
    })
  end

  defp usage!(company, cost) do
    Finances.record_token_usage(%{
      company_id: company.id,
      provider: "claude_code",
      model: "test",
      total_tokens: 100,
      cost_usd: Decimal.new(cost)
    })
  end
end
