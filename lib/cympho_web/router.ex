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

  scope "/", CymphoWeb do
    pipe_through :browser

    get "/", PageController, :home

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
    live "/agents/new", AgentLive.New
    live "/agents/:id", AgentLive.Show
    live "/agents/:id/edit", AgentLive.Edit
    live "/routines", RoutineLive.Index
    live "/routines/new", RoutineLive.New
    live "/routines/:id", RoutineLive.Show
    live "/routines/:id/edit", RoutineLive.Edit
    live "/settings", SettingsLive.Index
    live "/execution-policies", ExecutionPolicyLive.Index
    live "/execution-policies/new", ExecutionPolicyLive.New
    live "/execution-policies/:id", ExecutionPolicyLive.Show
    live "/execution-policies/:id/edit", ExecutionPolicyLive.Edit
  end

  scope "/api", CymphoWeb do
    pipe_through :api

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
end
