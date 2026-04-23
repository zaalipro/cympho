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

  pipeline :github_webhook do
    plug :accepts, ["json"]
    plug CymphoWeb.Plugs.GithubWebhookVerification
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
    live "/agents", AgentLive.Index
    live "/agents/new", AgentLive.New
    live "/agents/:id", AgentLive.Show
    live "/agents/:id/edit", AgentLive.Edit
    live "/routines/:id", RoutineLive.Show
  end

  scope "/api", CymphoWeb do
    pipe_through :api

    resources "/users", UserController, only: [:index, :show, :create, :update, :delete]
    patch "/users/:id/notification-prefs", UserController, :update_notification_prefs

    get "/search", SearchController, :search

    resources "/goals", GoalController, only: [:index, :show, :create, :update, :delete]

    post "/telegram/webhook", TelegramController, :webhook
    post "/github/webhook", GithubController, :webhook

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

    get "/issues/:issue_id/documents", DocumentController, :index
    get "/issues/:issue_id/documents/:key", DocumentController, :show
    put "/issues/:issue_id/documents/:key", DocumentController, :upsert
    delete "/issues/:issue_id/documents/:key", DocumentController, :delete
    get "/issues/:issue_id/documents/:key/revisions", DocumentController, :revisions
  end
end
