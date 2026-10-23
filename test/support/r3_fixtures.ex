defmodule Cympho.R3Fixtures do
  @moduledoc """
  The r3 sample company, Northwind Software, as one dataset for tests and the
  local demo seed (redesign build plan §5.4; the design brief's §4 dataset with
  the owner decisions applied: a question parks its task, NW-10 is unassigned).

  Rows are inserted directly with `Repo.insert!`, so no dispatcher, wake,
  notification or broadcast side effects run. Times are fixed offsets before an
  anchor (seconds zeroed). The anchor stands for the dataset's "Wed 21 Oct
  07:40": `at(anchor, 228)` is "03:52".

  Options: `:email` (default unique per call), `:password` (default nil: the
  user gets no password hash), `:slug` (default unique per call).
  """

  alias Cympho.Activities.Activity
  alias Cympho.Agents.Agent
  alias Cympho.Authentication
  alias Cympho.BoardApprovals.BoardApproval
  alias Cympho.Comments.Comment
  alias Cympho.Companies.Company
  alias Cympho.Companies.CompanyMembership
  alias Cympho.Finances.BudgetPolicy
  alias Cympho.Finances.TokenUsage
  alias Cympho.Goals.Goal
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.Issues.Issue
  alias Cympho.Issues.IssueThreadInteraction
  alias Cympho.Projects.Project
  alias Cympho.Repo
  alias Cympho.RuntimeProfiles
  alias Cympho.Secrets
  alias Cympho.Users
  alias Cympho.Wakes.AgentWake
  alias Cympho.WorkProducts.IssueWorkProduct

  @goal "Ship the Northwind invoicing app to its first 10 paying customers"
  @pause_reason "3 failed attempts in a row on NW-10"
  @default_question_message "The agent needs your answers before continuing."
  @pr_base "https://github.com/northwind-demo/invoicing-app/pull/"

  # {name, role, reports to, title, adapter, status, created (minutes before the anchor)}
  @agents [
    {"Ada", :ceo, nil, "Chief Executive Officer", :claude_code, :idle, 4988},
    {"Theo", :cto, "Ada", "Chief Technology Officer", :claude_code, :running, 4988},
    {"Priya", :product_manager, "Ada", "Product Manager", :claude_code, :idle, 4988},
    {"Jun", :designer, "Priya", "Designer", :claude_code, :idle, 4988},
    {"Ravi", :engineer, "Theo", "Software Engineer", :claude_code, :idle, 4988},
    {"Mira", :engineer, "Theo", "Software Engineer", :codex, :paused, 4988},
    {"Sol", :content_strategist, "Priya", "Content Strategist", :openai_chat, :idle, 4130}
  ]

  # {#, agent, task, started, ended (nil = running), status, cost, error}
  @runs [
    {1, "Ravi", "NW-6", 2438, 2416, "completed", "2.31", nil},
    {2, "Ada", "NW-1", 800, 790, "completed", "1.06", nil},
    {3, "Ravi", "NW-6", 540, 509, "completed", "3.42", nil},
    {4, "Theo", "NW-3", 500, 468, "completed", "2.50", nil},
    {5, "Sol", "NW-8", 350, 326, "completed", "0.44", nil},
    {6, "Mira", "NW-10", 342, 340, "failed", "0.29", "Test database not reachable"},
    {7, "Mira", "NW-10", 300, 298, "failed", "0.29", "Test database not reachable"},
    {8, "Mira", "NW-10", 259, 229, "timed_out", "3.10",
     "Timed out after 30 minutes while running the test suite"},
    {9, "Ravi", "NW-6", 215, 208, "completed", "1.12", nil},
    {10, "Ravi", "NW-4", 160, 129, "completed", "0.58", nil},
    {11, "Theo", nil, 120, 102, "completed", "0.94", nil},
    {12, "Jun", "NW-9", 105, 80, "completed", "0.47", nil},
    {13, "Priya", "NW-7", 70, 53, "completed", "0.61", nil},
    {14, "Theo", "NW-9", 28, nil, "running", "0", nil}
  ]

  # Spend not linked to a run: {agent, task or nil, cost, minutes before the anchor}
  @usages [
    {"Ada", "NW-1", "23.54", 4960},
    {"Ada", "NW-11", "3.10", 3680},
    {"Ada", nil, "10.50", 4240},
    {"Theo", "NW-2", "14.00", 3820},
    {"Theo", "NW-3", "20.25", 2620},
    {"Theo", nil, "3.91", 4180},
    {"Priya", "NW-7", "4.59", 2770},
    {"Priya", nil, "9.70", 4060},
    {"Jun", "NW-9", "9.33", 2320},
    {"Jun", nil, "2.55", 3940},
    {"Ravi", "NW-2", "27.30", 3880},
    {"Ravi", "NW-4", "8.82", 2680},
    {"Ravi", nil, "9.25", 4000},
    {"Mira", "NW-10", "8.00", 2260},
    {"Mira", "NW-10", "7.72", 1780},
    {"Sol", "NW-8", "6.46", 4030},
    {"Sol", nil, "0.35", 3970}
  ]

  @doc "Inserts the dataset and returns its records keyed by name."
  def northwind!(opts \\ []) do
    unique = System.unique_integer([:positive])
    anchor = DateTime.utc_now() |> DateTime.truncate(:second) |> Map.put(:second, 0)
    at = &at(anchor, &1)

    company =
      Repo.insert!(%Company{
        name: "Northwind Software",
        slug: Keyword.get(opts, :slug, "northwind-software-#{unique}"),
        status: "active",
        issue_prefix: "NW",
        issue_counter: 11,
        budget_monthly_cents: 30_000,
        require_board_approval_for_new_agents: true,
        governance_config: %{},
        inserted_at: at.(4990),
        updated_at: at.(4990)
      })

    user = insert_user!(company, opts, unique, at.(4990))

    Repo.insert!(%CompanyMembership{
      user_id: user.id,
      company_id: company.id,
      role: "owner",
      is_board_member: true,
      inserted_at: at.(4990),
      updated_at: at.(4990)
    })

    project =
      Repo.insert!(%Project{
        company_id: company.id,
        name: "Invoicing app",
        prefix: "NW",
        status: :active,
        inserted_at: at.(4990),
        updated_at: at.(4990)
      })

    goal =
      Repo.insert!(%Goal{
        company_id: company.id,
        project_id: project.id,
        title: @goal,
        priority: "critical",
        status: "active",
        inserted_at: at.(4990),
        updated_at: at.(4990)
      })

    # Mirrors the unowned onboarding hard stop (`budget_id` nil).
    budget_policy =
      Repo.insert!(%BudgetPolicy{
        company_id: company.id,
        scope: "company",
        period: "monthly",
        budget_limit_usd: Decimal.new("300.00"),
        warning_threshold_pct: Decimal.new("80.0"),
        action_on_exceed: "block",
        is_active: true,
        inserted_at: at.(4989),
        updated_at: at.(4989)
      })

    {:ok, secret} =
      Secrets.create_secret(%{
        company_id: company.id,
        scope: "company",
        key: "OPENAI_API_KEY",
        value: "sk-northwind-demo-#{Ecto.UUID.generate()}",
        description: "OpenAI key for Codex and the chat runtime"
      })

    secret = secret |> Ecto.Changeset.change(inserted_at: at.(4985)) |> Repo.update!()

    agents = insert_agents!(company, project, at)
    ctx = %{anchor: anchor, company: company, project: project, goal: goal, agents: agents}
    issues = insert_issues!(ctx, user, at)
    ctx = Map.merge(ctx, %{user: user, issues: issues})

    insert_blocker!(issues["NW-4"], issues["NW-5"], at.(4988))
    insert_work_products!(ctx, at)
    insert_comments!(ctx, at)
    questions = insert_questions!(ctx, at)
    insert_activities!(ctx, at)

    # `Wakes.wake_for_final_review/1` wakes the assignee when there is one.
    review_wake =
      Repo.insert!(%AgentWake{
        agent_id: agents["Ravi"].id,
        issue_id: issues["NW-4"].id,
        reason: "final_review_required",
        status: "pending",
        triggered_by_type: "system",
        triggered_by_id: issues["NW-4"].id,
        inserted_at: at.(129)
      })

    hire = insert_hire!(ctx, at)
    runs = insert_runs!(ctx, at)
    insert_usages!(ctx, runs, at)

    Map.merge(ctx, %{
      budget_policy: budget_policy,
      secret: secret,
      questions: questions,
      review_wake: review_wake,
      hire: hire,
      runs: runs
    })
  end

  @doc "The time `minutes` before `anchor`."
  def at(%DateTime{} = anchor, minutes), do: DateTime.add(anchor, -minutes * 60, :second)

  defp insert_user!(company, opts, unique, inserted_at) do
    email = Keyword.get(opts, :email, "maya+#{unique}@northwind.example")
    attrs = %{email: email, name: "Maya Chen"}

    {:ok, user} =
      case Keyword.get(opts, :password) do
        nil -> Users.create_user(attrs)
        password -> Authentication.register_user(Map.put(attrs, :password, password))
      end

    user
    |> Ecto.Changeset.change(
      theme: "system",
      company_id: company.id,
      inserted_at: inserted_at,
      updated_at: inserted_at
    )
    |> Repo.update!()
  end

  defp insert_agents!(company, project, at) do
    Enum.reduce(@agents, %{}, fn {name, role, parent, title, adapter, status, created}, acc ->
      parent_id = parent && acc[parent].id
      {config, runtime_config} = agent_runtime(adapter)

      agent =
        Repo.insert!(
          %Agent{
            company_id: company.id,
            project_id: project.id,
            parent_id: parent_id,
            created_by_agent_id: parent_id,
            name: name,
            title: title,
            role: role,
            adapter: adapter,
            status: status,
            config: config,
            runtime_config: runtime_config,
            context_mode: "company",
            max_concurrent_jobs: 1,
            inserted_at: at.(created),
            updated_at: at.(created)
          }
          |> Map.merge(paused_fields(name, at))
        )

      Map.put(acc, name, agent)
    end)
  end

  # Mira was paused automatically by a breaker, so nobody is recorded as the pauser.
  defp paused_fields("Mira", at) do
    %{
      governance_status: "paused",
      governance_reasoning: @pause_reason,
      paused_at: at.(228),
      pause_reason: @pause_reason,
      paused_by_user_id: nil,
      updated_at: at.(228)
    }
  end

  defp paused_fields(_name, _at), do: %{}

  defp agent_runtime(:claude_code), do: {%{}, %{"autonomous" => true}}

  defp agent_runtime(:codex) do
    profile = RuntimeProfiles.config("codex-mini")

    {Map.take(profile, ["provider", "model"]),
     %{"autonomous" => true, "profile_id" => "codex-mini", "pricing" => profile["pricing"]}}
  end

  defp agent_runtime(:openai_chat) do
    pricing = RuntimeProfiles.config("codex-mini")["pricing"]
    {%{"model" => "gpt-5.4-mini"}, %{"autonomous" => true, "pricing" => pricing}}
  end

  defp insert_issues!(ctx, user, at) do
    %{agents: agents} = ctx
    setup = %{origin_type: "onboarding", created_at: 4988}

    specs = [
      {1, "Create the first autonomous execution plan", :done, "Ada", :high, setup,
       %{
         description:
           "Break the company goal into CEO, CTO, product, design, and engineering work. Create follow-up issues for the first execution cycle.",
         completed: 4950,
         updated: 4950
       }},
      {2, "Set up the engineering environment and CI pipeline", :done, "Theo", :high, setup,
       %{
         description:
           "Establish the development environment, linting, formatting, and CI pipeline so engineers can ship reliably.",
         completed: 3775,
         updated: 3775,
         pr: 38
       }},
      {3, "Define the technical architecture", :done, "Theo", :high, setup,
       %{
         description:
           "Research and document the core technical architecture: stack choices, data model, API surface, and deployment strategy.",
         completed: 468,
         updated: 468
       }},
      {4, "Implement the first core feature", :in_review, "Ravi", :high, setup,
       %{
         description:
           "Pick the highest-value feature from the execution plan and implement it end to end with tests.",
         updated: 129,
         pr: 42
       }},
      {5, "Ship a working demo for stakeholder review", :todo, "Ada", :medium, setup,
       %{
         description:
           "Package the first iteration into a reviewable demo. Document what works, what is missing, and what is next.",
         updated: 4988
       }},
      {6, "Connect Stripe payments", :blocked, "Ravi", :high, %{user: user, created_at: 2460},
       %{
         description:
           "Customers should be able to pay an invoice by card. Use Stripe Checkout. Keep it simple for launch: one-time payments, USD only.",
         updated: 208,
         pr: 44
       }},
      {7, "Decide pricing tiers for launch", :blocked, "Priya", :medium,
       %{agent: "Ada", created_at: 2785},
       %{description: "Choose the plans and prices we launch with.", updated: 53}},
      {8, "Write landing page and pricing copy", :done, "Sol", :medium,
       %{agent: "Priya", created_at: 4100},
       %{
         description: "Write the landing page and the pricing page copy.",
         completed: 326,
         updated: 326
       }},
      {9, "Design empty states for the invoice dashboard", :in_review, "Jun", :low,
       %{agent: "Priya", created_at: 2375},
       %{description: "Design the empty states of the invoice dashboard.", updated: 80}},
      {10, "Add automated tests for invoice totals", :blocked, nil, :high,
       %{agent: "Theo", created_at: 2530},
       %{
         description: "Cover invoice totals, taxes and rounding with automated tests.",
         updated: 228,
         role: "engineer"
       }},
      {11, "Native mobile app spike", :cancelled, "Ada", :low, %{agent: "Ada", created_at: 3700},
       %{
         description: "Try a native mobile app for invoices.",
         cancelled: 2720,
         updated: 2720
       }}
    ]

    Map.new(specs, fn {number, title, status, assignee, priority, origin, extra} ->
      assignee = assignee && agents[assignee]
      pr = extra[:pr]

      issue =
        Repo.insert!(%Issue{
          company_id: ctx.company.id,
          project_id: ctx.project.id,
          goal_id: ctx.goal.id,
          issue_number: number,
          identifier: "NW-#{number}",
          title: title,
          description: extra.description,
          status: status,
          priority: priority,
          assignee_id: assignee && assignee.id,
          assigned_role: (assignee && to_string(assignee.role)) || extra[:role],
          origin_type: origin[:origin_type],
          created_by_user_id: origin[:user] && origin.user.id,
          created_by_agent_id: origin[:agent] && agents[origin.agent].id,
          # `github_pr_url` stays nil: it is unique across companies (GitHub webhook key).
          github_pr_number: pr,
          completed_at: extra[:completed] && at.(extra.completed),
          cancelled_at: extra[:cancelled] && at.(extra.cancelled),
          inserted_at: at.(origin.created_at),
          updated_at: at.(extra.updated)
        })

      {"NW-#{number}", issue}
    end)
  end

  defp insert_blocker!(%Issue{} = blocking, %Issue{} = blocked, inserted_at) do
    Repo.insert_all("issue_blockers", [
      %{
        blocked_issue_id: Ecto.UUID.dump!(blocked.id),
        blocking_issue_id: Ecto.UUID.dump!(blocking.id),
        inserted_at: inserted_at,
        updated_at: inserted_at
      }
    ])
  end

  defp insert_work_products!(%{agents: agents, issues: issues}, at) do
    [
      {"NW-1", "Ada", "document", "Execution plan v1", nil, 4955},
      {"NW-2", "Theo", "code_change", "PR #38 CI pipeline", 38, 3800},
      {"NW-3", "Theo", "document", "Architecture: Phoenix, Postgres, Stripe", nil, 470},
      {"NW-4", "Ravi", "code_change", "PR #42 Invoice creation and PDF export", 42, 130},
      {"NW-4", "Ravi", "document", "Release notes", nil, 129},
      {"NW-6", "Ravi", "document", "Payment flow spec", nil, 2416},
      {"NW-6", "Ravi", "code_change", "PR #44 Stripe Checkout (draft)", 44, 509},
      {"NW-7", "Priya", "document", "Pricing options", nil, 54},
      {"NW-8", "Sol", "document", "Landing page copy v2", nil, 327},
      {"NW-9", "Jun", "url", "Empty states (Figma)", :figma, 81}
    ]
    |> Enum.each(fn {issue, agent, kind, title, link, minutes} ->
      Repo.insert!(%IssueWorkProduct{
        issue_id: issues[issue].id,
        created_by_agent_id: agents[agent].id,
        kind: kind,
        title: title,
        url: work_product_url(link),
        inserted_at: at.(minutes),
        updated_at: at.(minutes)
      })
    end)
  end

  defp work_product_url(nil), do: nil
  defp work_product_url(:figma), do: "https://www.figma.com/design/northwind-demo/empty-states"
  defp work_product_url(pr), do: @pr_base <> Integer.to_string(pr)

  defp insert_comments!(%{agents: agents, issues: issues, user: user}, at) do
    approved = "[review] Verdict: approved.\nApproved and closed by the human reviewer."

    [
      {"NW-1", {:user, user.id}, approved, 4950},
      {"NW-2", {:user, user.id}, approved, 3775},
      {"NW-4", {:agent, "Ravi"},
       "Ready for your review: Invoice creation and PDF export — PR #42. 38 tests pass.", 129},
      {"NW-6", {:agent, "Ravi"},
       "Plan: 1) a Checkout session per invoice, 2) a webhook marks the invoice paid, 3) a receipt email.",
       2416},
      {"NW-6", {:agent, "Ravi"},
       "Draft PR #44 opens a Checkout session from the invoice page. 38 tests pass. Webhook next.",
       509},
      {"NW-6", {:agent, "Theo"},
       "Use idempotency keys on the webhook — Stripe retries deliveries.", 490},
      {"NW-6", {:agent, "Ravi"},
       "While you decide on retries, I'm wiring the webhook handler with idempotency keys.", 14},
      {"NW-11", {:user, user.id}, "Not before the first 10 customers", 2720}
    ]
    |> Enum.each(fn {issue, author, body, minutes} ->
      {author_type, author_id} =
        case author do
          {:user, id} -> {"user", id}
          {:agent, name} -> {"agent", agents[name].id}
        end

      inserted_at = %{at.(minutes) | microsecond: {0, 6}}

      Repo.insert!(%Comment{
        issue_id: issues[issue].id,
        author_type: author_type,
        author_id: author_id,
        body: body,
        inserted_at: inserted_at,
        updated_at: inserted_at
      })
    end)
  end

  # A question parks its task: Blocked, assignee kept, `work_mode_wait` pinned to
  # the interaction so answering moves it back to To do (agent_actions.ex).
  defp insert_questions!(%{agents: agents, issues: issues}, at) do
    [
      {"Q1", "NW-6", "Ravi", 208,
       "When a customer's card payment fails, what should happen first?",
       [
         "Retry automatically after 3 days",
         "Email the customer first",
         "Both: email now, retry in 3 days"
       ]},
      {"Q2", "NW-7", "Priya", 53, "Which pricing should we launch with?",
       ["Two tiers: Starter $19, Pro $49", "One plan: $29/month", "I'll write it"]}
    ]
    |> Map.new(fn {key, issue_key, agent, minutes, question, options} ->
      issue = issues[issue_key]

      interaction =
        Repo.insert!(%IssueThreadInteraction{
          issue_id: issue.id,
          created_by_agent_id: agents[agent].id,
          kind: :ask_user_questions,
          status: :pending,
          payload: %{
            "message" => @default_question_message,
            "questions" => [%{"question" => question, "options" => options}]
          },
          inserted_at: at.(minutes),
          updated_at: at.(minutes)
        })

      issue
      |> Ecto.Changeset.change(
        monitor_state: %{
          "work_mode_wait" => %{
            "interaction_id" => interaction.id,
            "kind" => "ask_user_questions"
          }
        }
      )
      |> Repo.update!()

      {key, interaction}
    end)
  end

  defp insert_activities!(%{agents: agents, issues: issues, user: user, company: company}, at) do
    [
      {"NW-1", "user", user.id, "approval_approved", %{}, 4950},
      {"NW-2", "user", user.id, "approval_approved", %{}, 3775},
      {"NW-10", "system", nil, "rehomed_on_pause",
       %{
         "previous_assignee_id" => agents["Mira"].id,
         "previous_status" => "blocked",
         "target_status" => "blocked",
         "reason" => @pause_reason
       }, 228},
      {"NW-11", "user", user.id, "status_changed", %{"from" => "todo", "to" => "cancelled"}, 2720}
    ]
    |> Enum.each(fn {issue, actor_type, actor_id, action, metadata, minutes} ->
      Repo.insert!(%Activity{
        company_id: company.id,
        issue_id: issues[issue].id,
        actor_type: actor_type,
        actor_id: actor_id,
        action: action,
        metadata: metadata,
        inserted_at: at.(minutes)
      })
    end)
  end

  defp insert_hire!(%{agents: agents, company: company}, at) do
    theo = agents["Theo"]

    Repo.insert!(%BoardApproval{
      company_id: company.id,
      requested_by_agent_id: theo.id,
      title: "Hire a QA engineer",
      description:
        "Mira's test runs timed out 3 times tonight. A QA engineer would own the test suite and release checks. Runs on Claude Code; expected about $25–40 per 30 days.",
      category: "agent_hire",
      status: "pending",
      proposal_data: %{
        "attrs" => %{
          "name" => "QA engineer",
          "title" => "QA Engineer",
          "role" => "qa_engineer",
          "adapter" => "claude_code",
          "company_id" => company.id,
          "parent_id" => theo.id
        },
        "parent_agent_id" => theo.id
      },
      review_deadline: DateTime.add(at.(102), 7 * 24 * 3600, :second),
      inserted_at: at.(102),
      updated_at: at.(102)
    })
  end

  defp insert_runs!(%{agents: agents, issues: issues, company: company, anchor: anchor}, at) do
    Map.new(@runs, fn {number, agent_name, issue_key, started, ended, status, cost, error} ->
      agent = agents[agent_name]
      completed_at = ended && at.(ended)
      {input_tokens, output_tokens} = if number == 8, do: {1_900_000, 370_000}, else: {0, 0}

      run =
        Repo.insert!(%Run{
          company_id: company.id,
          agent_id: agent.id,
          issue_id: issue_key && issues[issue_key].id,
          status: status,
          adapter: to_string(agent.adapter),
          invocation_source: "heartbeat",
          started_at: at.(started),
          completed_at: completed_at,
          last_heartbeat_at: completed_at || anchor,
          error_reason: error,
          cost_usd: Decimal.new(cost),
          input_tokens: input_tokens,
          output_tokens: output_tokens,
          inserted_at: at.(started),
          updated_at: completed_at || anchor
        })

      {number, run}
    end)
  end

  defp insert_usages!(%{agents: agents, issues: issues} = ctx, runs, at) do
    linked =
      for {_number, %Run{status: status} = run} <- runs, status != "running" do
        agent = Enum.find_value(agents, fn {_name, a} -> if a.id == run.agent_id, do: a end)
        {agent, run.issue_id, run.cost_usd, run.completed_at, run}
      end

    unlinked =
      for {agent_name, issue_key, cost, minutes} <- @usages do
        {agents[agent_name], issue_key && issues[issue_key].id, Decimal.new(cost), at.(minutes),
         nil}
      end

    Enum.each(linked ++ unlinked, fn {agent, issue_id, cost, inserted_at, run} ->
      Repo.insert!(%TokenUsage{
        company_id: ctx.company.id,
        agent_id: agent.id,
        issue_id: issue_id,
        project_id: issue_id && ctx.project.id,
        goal_id: issue_id && ctx.goal.id,
        heartbeat_run_id: run && run.id,
        provider: to_string(agent.adapter),
        # `HeartbeatEngine` records "unknown" when a runtime reports no model.
        model: agent.config["model"] || "unknown",
        input_tokens: (run && run.input_tokens) || 0,
        output_tokens: (run && run.output_tokens) || 0,
        total_tokens: ((run && run.input_tokens) || 0) + ((run && run.output_tokens) || 0),
        cost_usd: cost,
        inserted_at: inserted_at,
        updated_at: inserted_at
      })
    end)
  end
end
