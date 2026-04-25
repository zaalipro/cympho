defmodule CymphoWeb.Router do
  use CymphoWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {CymphoWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :board do
    plug CymphoWeb.Plugs.BoardAuth
  end

  scope "/", CymphoWeb do
    pipe_through :browser

    live_session :default, on_mount: [{CymphoWeb.UserAuth, :default}] do
      live "/", DashboardLive.Index, :home
      live "/dashboard", DashboardLive.Index
      live "/issues", IssueLive.Index
      live "/issues/new", IssueLive.New
      live "/issues/:id", IssueLive.Show
      live "/projects", ProjectLive.Index
      live "/projects/new", ProjectLive.New
      live "/projects/:id", ProjectLive.Show
      live "/projects/:id/edit", ProjectLive.Edit
      live "/goals", GoalLive.Index
      live "/goals/new", GoalLive.New
      live "/goals/:id", GoalLive.Show
      live "/goals/:id/edit", GoalLive.Edit
      live "/kanban", KanbanLive.Index
      live "/labels", LabelLive.Index
      live "/approvals", ApprovalLive.Index
      live "/approvals/:id", ApprovalLive.Show
      live "/agents", AgentLive.Index
      live "/agents/:id", AgentLive.Show
      live "/org-chart", OrgChartLive
      live "/routines", RoutineLive.Index
      live "/routines/new", RoutineLive.New
      live "/routines/:id", RoutineLive.Show
      live "/routines/:id/edit", RoutineLive.Edit
      live "/onboarding", OnboardingLive.Index
      live "/settings", SettingsLive.Index
      live "/execution-policies", ExecutionPolicyLive.Index
      live "/execution-policies/new", ExecutionPolicyLive.New
      live "/execution-policies/:id", ExecutionPolicyLive.Show
      live "/execution-policies/:id/edit", ExecutionPolicyLive.Edit
      live "/companies", CompanyLive.Index
      live "/companies/new", CompanyLive.Index, :new
      live "/companies/:id", CompanyLive.Show
      live "/skills", SkillLive.Index
      live "/skills/new", SkillLive.New
      live "/skills/:id", SkillLive.Show
      live "/skills/:id/edit", SkillLive.Edit
      live "/plugins", PluginLive.Index
      live "/plugins/new", PluginLive.New
      live "/plugins/:id", PluginLive.Show
      live "/plugins/:id/edit", PluginLive.Edit
      live "/plugins/:id/settings", PluginLive.Show, :settings
      live "/workspace/:issue_id", WorkspaceLive.Show
    live "/workspaces", WorkspaceLive.Index
    live "/workspaces/:id", WorkspaceLive.ShowWorkspace
    live "/workspaces/:id/exec/:exec_id", WorkspaceLive.ExecWorkspace
      live "/profile/:id", ProfileLive.Show
      live "/profile/:id/edit", ProfileLive.Edit
    end

    live_session :board_governed, on_mount: [{CymphoWeb.UserAuth, :default}, {CymphoWeb.Live.BoardAuth, :default}] do
      live "/agents/new", AgentLive.New
      live "/agents/:id/edit", AgentLive.Edit
      live "/budgets", BudgetLive.Index
      live "/budgets/new", BudgetLive.Index, :new
      live "/budgets/:id", BudgetLive.Show
      live "/budgets/:id/edit", BudgetLive.Show, :edit
      live "/companies/:id/edit", CompanyLive.Show, :edit
    end
  end

  scope "/api", CymphoWeb do
    pipe_through :api

    post "/register", RegistrationController, :create
    post "/login", LoginController, :create

    resources "/users", UserController, only: [:index, :show, :create, :update, :delete]
    patch "/users/:id/notification-prefs", UserController, :update_notification_prefs

    get "/search", SearchController, :search
    get "/dashboard", DashboardController, :index

    resources "/goals", GoalController, only: [:index, :show, :create, :update, :delete]

    post "/telegram/webhook", TelegramController, :webhook
    post "/github/webhook", GithubController, :webhook

    resources "/labels", LabelController, only: [:index, :show, :create, :update, :delete]
    resources "/approvals", ApprovalController, only: [:index, :show, :create, :update]

    resources "/routines", RoutineController, only: [:index, :show, :create, :update, :delete]
    patch "/routines/:id/pause", RoutineController, :pause
    patch "/routines/:id/resume", RoutineController, :resume
    patch "/routines/:id/archive", RoutineController, :archive
    post "/routines/:id/run", RoutineController, :run
    get "/routines/:id/runs", RoutineController, :runs

    resources "/routines/:routine_id/triggers", RoutineTriggerController,
      only: [:index, :create, :show, :update, :delete],
      name: "routine_trigger"

    post "/routine-triggers/:id/rotate-secret", RoutineTriggerController, :rotate_secret

    # Public webhook endpoint (no auth, validates via secret header)
    post "/routine-triggers/:public_id/fire", RoutineTriggerController, :fire

    resources "/issues", IssueController, only: [:create, :show]

    get "/issues/:issue_id/labels", IssueLabelController, :index
    post "/issues/:issue_id/labels", IssueLabelController, :add
    delete "/issues/:issue_id/labels/:label_id", IssueLabelController, :remove
    put "/issues/:issue_id/labels", IssueLabelController, :set

    post "/issues/:issue_id/execution-policy/assign", IssueExecutionPolicyController, :assign
    post "/issues/:issue_id/execution-policy/decide", IssueExecutionPolicyController, :decide
    get "/issues/:issue_id/documents", DocumentController, :index
    get "/issues/:issue_id/documents/:key", DocumentController, :show
    put "/issues/:issue_id/documents/:key", DocumentController, :upsert
    delete "/issues/:issue_id/documents/:key", DocumentController, :delete
    get "/issues/:issue_id/documents/:key/revisions", DocumentController, :revisions

    get "/issues/:issue_id/activities", ActivityController, :index
    get "/issues/:issue_id/activities/statistics", ActivityController, :statistics
    get "/activities/:id", ActivityController, :show
    get "/companies/:company_id/activities/timeline", ActivityController, :company_timeline

    # MCP server endpoints
    get "/mcp/tools", McpController, :tools
    post "/mcp/call", McpController, :call

    # Company portability & multi-tenancy
    resources "/companies", CompanyController, only: [:index, :show, :create, :update, :delete]
    get "/companies/:company_id/members", CompanyController, :list_members
    post "/companies/:company_id/members", CompanyController, :add_member
    delete "/companies/:company_id/members/:user_id", CompanyController, :remove_member
    get "/companies/:company_id/invites", CompanyController, :list_invites
    post "/companies/:company_id/invites", CompanyController, :create_invite
    delete "/companies/:company_id/invites/:invite_id", CompanyController, :revoke_invite
    post "/invites/:token/accept", CompanyController, :accept_invite
    get "/companies/:company_id/join-requests", CompanyController, :list_join_requests
    post "/companies/:company_id/join-requests", CompanyController, :create_join_request
    post "/companies/:company_id/join-requests/:request_id/approve", CompanyController, :approve_join_request
    post "/companies/:company_id/join-requests/:request_id/reject", CompanyController, :reject_join_request
    get "/companies/:company_id/export", CompanyController, :export
    post "/companies/import", CompanyController, :import_company

    # Workspace & Runtime Services
    resources "/workspaces", WorkspaceController, only: [:index, :show, :create, :update, :delete]
    get "/workspaces/:id/exec-workspaces", WorkspaceController, :list_exec_workspaces
    post "/workspaces/:id/exec-workspaces", WorkspaceController, :create_exec_workspace
    get "/exec-workspaces/:id", WorkspaceController, :show_exec_workspace
    patch "/exec-workspaces/:id", WorkspaceController, :update_exec_workspace
    delete "/exec-workspaces/:id", WorkspaceController, :destroy_exec_workspace
    get "/exec-workspaces/:id/default-branch", WorkspaceController, :detect_default_branch
    patch "/workspaces/:id/worktree-config", WorkspaceController, :update_worktree_config
    post "/exec-workspaces/:id/seed", WorkspaceController, :seed_worktree
    post "/exec-workspaces/:id/secrets", WorkspaceController, :inject_secrets
    get "/exec-workspaces/:id/services", WorkspaceController, :list_services
    post "/exec-workspaces/:id/services", WorkspaceController, :create_service
    patch "/services/:id/start", WorkspaceController, :start_service
    patch "/services/:id/stop", WorkspaceController, :stop_service
    patch "/services/:id/restart", WorkspaceController, :restart_service
    get "/exec-workspaces/:id/operations", WorkspaceController, :list_operations
    post "/exec-workspaces/:id/leases", WorkspaceController, :create_lease
    delete "/leases/:id", WorkspaceController, :revoke_lease
  end

  scope "/api", CymphoWeb do
    pipe_through [:api, CymphoWeb.Plugs.AgentAuth]

    get "/agents/:id/inbox", AgentController, :inbox
    patch "/agents/:id/status", AgentController, :update_status

    get "/issues/:issue_id/attachments", AttachmentController, :index
    post "/issues/:issue_id/attachments", AttachmentController, :create
    get "/attachments/:id", AttachmentController, :show
    get "/attachments/:id/download", AttachmentController, :download
    delete "/attachments/:id", AttachmentController, :delete
  end

  # Board-governed governance mutations
  scope "/api", CymphoWeb do
    pipe_through [:api, :board]

    post "/agents", AgentController, :create
    resources "/budgets", BudgetController, only: [:create, :update, :delete]
  end
end
