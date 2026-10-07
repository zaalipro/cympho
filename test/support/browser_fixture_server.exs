# Executed only by scripts/validation_browser.py, never by test compilation.
# Passive seeded runs are UI fixtures, not real process or progress evidence.
defmodule Cympho.BrowserFixtureServer do
  require Logger
  alias Cympho.{Agents, Authentication, Companies, Inbox, Issues, Projects, Repo, Workspaces}
  alias Cympho.Comments.Comment
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.WorkProducts.IssueWorkProduct
  alias Cympho.Wakes.AgentWake

  @tables [
    Companies.Company,
    Companies.CompanyMembership,
    Cympho.Users.User,
    Projects.Project,
    Agents.Agent,
    Issues.Issue,
    Run,
    Comment,
    IssueWorkProduct,
    AgentWake,
    Cympho.Inbox.InboxState,
    Cympho.Workspaces.ProjectWorkspace,
    Cympho.Finances.BudgetPolicy
  ]

  def run do
    Logger.configure(level: :warning)
    cfg = Application.fetch_env!(:cympho, Repo)
    root = System.fetch_env!("CYMPHO_BROWSER_ROOT")
    database = System.get_env("TEST_DB_NAME") || "cympho_test"

    unless Mix.env() == :test and Application.fetch_env!(:cympho, :env) == :test and
             Regex.match?(~r/\Acympho_test(?:_[a-z0-9_]+)?\z/, database) and
             cfg[:database] == database and cfg[:hostname] == "127.0.0.1" and
             cfg[:pool] == Ecto.Adapters.SQL.Sandbox and cfg[:url] == nil and
             System.get_env("MIX_TEST_PARTITION") == nil and
             (cfg[:port] || 5432) == 5432 and System.get_env("PORT") == "4329" and
             System.get_env("HTTP_BIND_IP") == "127.0.0.1" and
             String.starts_with?(root, "/tmp/cympho-browser-validation-") and
             File.dir?(root) do
      raise "unsafe browser fixture configuration"
    end

    Application.put_env(:cympho, Repo, Keyword.merge(cfg, pool_size: 2, timeout: 2_000))
    Application.put_env(:sentry, :dsn, nil)
    Application.put_env(:cympho, :open_telemetry, [])
    Application.put_env(:cympho, :auto_ignite_on_create, false)
    Application.put_env(:cympho, :llm_router_enabled?, false)
    Application.put_env(:cympho, :dispatcher_recover_on_boot?, false)

    for flag <- [
          :start_board_approval_executor?,
          :start_heartbeat_watchdog?,
          :start_health_checker?,
          :start_scheduler?,
          :start_import_transfer_sweeper?,
          :schedule_routine_triggers?,
          :restore_catalog_plugins?,
          :start_backlog_planner?,
          :start_oversight_patrol?,
          :start_decisions_executor?,
          :start_execution_policy_advancer?
        ] do
      Application.put_env(:cympho, flag, false)
    end

    Application.put_env(:cympho, :orchestrator, enabled: false, max_concurrent_agents: 1)
    Application.put_env(:cympho, :uploads_dir, Path.join(root, "uploads"))
    Application.put_env(:cympho, :storage_backend, Cympho.Attachments.Storage.LocalStorage)

    endpoint =
      Application.fetch_env!(:cympho, CymphoWeb.Endpoint)
      |> Keyword.merge(
        http: [ip: {127, 0, 0, 1}, port: 4329],
        url: [host: "127.0.0.1", port: 4329, scheme: "http"],
        check_origin: ["//127.0.0.1:4329"],
        server: true
      )

    Application.put_env(:cympho, CymphoWeb.Endpoint, endpoint)

    # Do not start Cympho.Application: its ungated notification/reassignment
    # children and telemetry poller are unnecessary for these passive flows.
    for app <- Application.spec(:cympho, :applications) -- [:os_mon, :ssh, :runtime_tools] do
      {:ok, _} = Application.ensure_all_started(app)
    end

    children = [
      Repo,
      {Phoenix.PubSub, name: Cympho.PubSub},
      {Task.Supervisor, name: Cympho.TaskSupervisor},
      Cympho.Readiness.Cache,
      {Registry, keys: :unique, name: Cympho.OrchestratorRegistry},
      {Registry, keys: :unique, name: Cympho.AdapterSessions.Registry},
      Cympho.AdapterSessions,
      {Cympho.RuntimeAdmission, max_total_runs: 1, max_local_runs: 1, memory_check?: false},
      Cympho.RateLimiting.BroadcastDedup,
      Cympho.RateLimiting.IpRateLimiter,
      Cympho.RateLimiting.AgentActionLimiter,
      Cympho.EventStore
    ]

    {:ok, supervisor} = Supervisor.start_link(children, strategy: :one_for_one)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)

    %{rows: [[^database]]} =
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        Ecto.Adapters.SQL.query!(Repo, "SELECT current_database()", [])
      end)

    baseline = Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, &counts/0)
    unless Enum.all?(baseline, &(&1 == 0)), do: raise("test fixture tables must be empty")
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true, ownership_timeout: 240_000)

    try do
      {:ok, _} = Supervisor.start_child(supervisor, CymphoWeb.Endpoint)
      fixtures = seed(root)
      File.write!(Path.join(root, "fixtures.json"), Jason.encode!(fixtures))
      %{status: "ready"} = Cympho.Readiness.report()
      File.write!(Path.join(root, "ready"), "127.0.0.1:4329 #{database} passive\n")
      IO.puts("VALIDATION_SERVER_READY database=#{database} dispatch=false port=4329")

      wait_for_stop(root, System.monotonic_time(:millisecond) + 180_000)
    after
      Supervisor.terminate_child(supervisor, CymphoWeb.Endpoint)
      Supervisor.terminate_child(supervisor, Cympho.TaskSupervisor)
      Ecto.Adapters.SQL.Sandbox.stop_owner(owner)
      {:ok, []} = Cympho.AdapterSessions.active_sessions()

      %{total_running: 0, local_running: 0, gateway_running: 0} =
        Cympho.RuntimeAdmission.snapshot()

      ^baseline = Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, &counts/0)
      Supervisor.stop(supervisor, :normal, 2_000)
      File.write!(Path.join(root, "cleanup.ok"), "rollback sessions=0 admission=0\n")
    end
  end

  defp counts, do: Enum.map(@tables, &Repo.aggregate(&1, :count))

  defp wait_for_stop(root, deadline) do
    unless File.exists?(Path.join(root, "stop")) or
             System.monotonic_time(:millisecond) >= deadline do
      Process.sleep(200)
      wait_for_stop(root, deadline)
    end
  end

  defp seed(root) do
    companies =
      for label <- ~w(A B C D), into: %{} do
        {:ok, company} =
          Companies.create_company(%{
            name: "Synthetic Company #{label}",
            slug: "browser-synthetic-#{String.downcase(label)}",
            issue_prefix: "V#{label}"
          })

        {label, company}
      end

    logins =
      for actor <- ~w(owner viewer single no_company), into: %{} do
        password = :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
        email = "browser-#{actor}@example.test"

        {:ok, user} =
          Authentication.register_user(%{
            email: email,
            name: "Synthetic #{actor}",
            password: password
          })

        memberships =
          if actor == "single",
            do: ["D"],
            else: if(actor == "no_company", do: [], else: ["A", "B"])

        for label <- memberships do
          {:ok, _} =
            Companies.create_membership(%{
              user_id: user.id,
              company_id: companies[label].id,
              role: if(actor == "viewer", do: "viewer", else: "owner"),
              is_board_member: actor != "viewer"
            })
        end

        if memberships != [] do
          user
          |> Ecto.Changeset.change(company_id: companies[hd(memberships)].id)
          |> Repo.update!()
        end

        {actor, %{email: email, password: password, user_id: user.id}}
      end

    File.write!(Path.join(root, "login.json"), Jason.encode!(logins))
    File.chmod!(Path.join(root, "login.json"), 0o600)

    data =
      for {label, company} <- companies, into: %{} do
        {:ok, project} =
          Projects.create_project(%{
            company_id: company.id,
            name: "Synthetic #{label} Project",
            prefix: "V#{label}"
          })

        {:ok, workspace} =
          Workspaces.create_project_workspace(%{
            company_id: company.id,
            project_id: project.id,
            name: "Private synthetic workspace",
            cwd: Path.join(root, "workspace"),
            is_primary: true
          })

        {:ok, worker} =
          Agents.create_agent(%{
            company_id: company.id,
            name: "Synthetic #{label} Researcher",
            role: :researcher,
            adapter: :process,
            status: :offline,
            config: %{"command" => "/usr/bin/false"}
          })

        {:ok, reviewer} =
          Agents.create_agent(%{
            company_id: company.id,
            name: "Synthetic #{label} Reviewer",
            role: :cto,
            adapter: :process,
            status: :offline,
            config: %{"command" => "/usr/bin/false"}
          })

        issues =
          for {key, status} <- [
                {"queue_approval", :in_review},
                {"inbox_approval", :in_review},
                {"queue_linked_blocker", :in_review},
                {"inbox_linked_blocker", :in_review},
                {"queue_feedback", :in_review},
                {"inbox_feedback", :in_review},
                {"missing_evidence", :in_review},
                {"rework", :todo},
                {"rework_latest_human", :todo},
                {"rework_latest_agent", :todo},
                {"blocked", :blocked},
                {"running", :in_progress},
                {"stale", :in_progress},
                {"completed", :done},
                {"failed", :blocked},
                {"cancelled", :cancelled},
                {"queued", :todo},
                {"pending", :todo}
              ],
              into: %{} do
            {:ok, issue} =
              Issues.create_issue(%{
                company_id: company.id,
                project_id: project.id,
                project_workspace_id: workspace.id,
                title: "Synthetic #{label} #{key}",
                description:
                  "Private synthetic browser fixture; seeded state is not execution evidence.",
                status: status,
                assigned_role: if(status == :in_review, do: "cto", else: "researcher"),
                assignee_id: if(status == :in_review, do: reviewer.id, else: worker.id),
                last_reviewer_id:
                  if(String.starts_with?(key, "rework"), do: reviewer.id, else: nil)
              })

            if key in ~w(queue_approval inbox_approval queue_linked_blocker inbox_linked_blocker) do
              evidence(issue, worker, reviewer)
            end

            if key in ~w(rework_latest_human rework_latest_agent) do
              issue
              |> Ecto.Changeset.change(last_human_reviewer_id: logins["owner"].user_id)
              |> Repo.update!()

              human_time = ~U[2026-11-01 12:02:00.100000Z]

              agent_time =
                if key == "rework_latest_human",
                  do: ~U[2026-10-31 12:01:00.900000Z],
                  else: ~U[2026-11-01 12:03:00.200000Z]

              for {type, id, body, timestamp} <- [
                    {"user", logins["owner"].user_id,
                     "[review] Verdict: changes requested.\nReason: Synthetic human feedback.",
                     human_time},
                    {"agent", reviewer.id,
                     "Review: Evidence inspected: synthetic document. Required changes: correct the gap. Verification required: inspect the document. Next action: resubmit.",
                     agent_time}
                  ] do
                Repo.insert!(%Comment{
                  issue_id: issue.id,
                  author_type: type,
                  author_id: id,
                  body: body,
                  inserted_at: timestamp
                })
              end
            end

            if status == :in_review do
              %AgentWake{}
              |> AgentWake.changeset(%{
                agent_id: reviewer.id,
                issue_id: issue.id,
                reason: "final_review_required",
                triggered_by_type: "system"
              })
              |> Repo.insert!()

              {:ok, _} = Inbox.ensure_inbox_entry(issue.id, reviewer.id)
            end

            if key in ~w(running stale completed failed cancelled queued pending) do
              now = DateTime.utc_now() |> DateTime.truncate(:second)
              run_status = if key == "stale", do: "running", else: key

              Repo.insert!(%Run{
                company_id: company.id,
                agent_id: worker.id,
                issue_id: issue.id,
                status: run_status,
                adapter: "process",
                started_at: DateTime.add(now, -60),
                last_heartbeat_at: DateTime.add(now, if(key == "stale", do: -3_600, else: 0)),
                completed_at:
                  if(run_status in ~w(completed failed cancelled), do: now, else: nil),
                run_metadata: %{"synthetic_seed_only" => true}
              })
            end

            {key, issue.id}
          end

        for key <- ~w(queue_linked_blocker inbox_linked_blocker) do
          {:ok, _} =
            Issues.add_blocker(
              Repo.get!(Issues.Issue, issues[key]),
              Repo.get!(Issues.Issue, issues["blocked"])
            )
        end

        {label, %{company_id: company.id, project_id: project.id, issues: issues}}
      end

    for {label, scope, limit} <- [{"A", "company", "10.00"}, {"B", "project", "3.00"}] do
      %Cympho.Finances.BudgetPolicy{}
      |> Cympho.Finances.BudgetPolicy.changeset(%{
        company_id: data[label].company_id,
        scope: scope,
        scope_id: if(scope == "project", do: data[label].project_id, else: nil),
        budget_limit_usd: limit
      })
      |> Repo.insert!()
    end

    %{
      companies: data,
      actors: Map.new(logins, fn {actor, login} -> {actor, %{user_id: login.user_id}} end),
      mode: "passive",
      real_process_evidence: false
    }
  end

  defp evidence(issue, worker, reviewer) do
    for {agent, body} <- [
          {worker,
           "[delivery] What happened: completed synthetic reviewable research. Files changed: none. Evidence produced: synthetic document and seeded process receipt. Verification: synthetic fixture only. Risks: no real execution proven. Current state: ready for review. Next decision: inspect evidence. Restart packet: inspect the synthetic document."},
          {reviewer,
           "[review] Verdict: accepted. What happened: inspected synthetic evidence. Evidence inspected: document and seeded receipt. Verification: synthetic fixture only. Gaps: none. Follow-up issues: none. Next decision: close. Restart packet: inspect synthetic evidence before closing."}
        ] do
      %Comment{}
      |> Comment.changeset(%{
        issue_id: issue.id,
        author_type: "agent",
        author_id: agent.id,
        body: body
      })
      |> Repo.insert!()
    end

    Repo.insert!(%Run{
      company_id: issue.company_id,
      agent_id: worker.id,
      issue_id: issue.id,
      status: "completed",
      adapter: "process",
      continuation_summary: "Synthetic seeded receipt, not real execution."
    })

    %IssueWorkProduct{}
    |> IssueWorkProduct.changeset(%{
      issue_id: issue.id,
      created_by_agent_id: worker.id,
      kind: "document",
      title: "Synthetic review evidence",
      description: "Private synthetic non-code evidence."
    })
    |> Repo.insert!()
  end
end

Cympho.BrowserFixtureServer.run()
