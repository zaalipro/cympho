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
    live "/kanban", KanbanLive.Index
    live "/labels", LabelLive.Index
    live "/agents", AgentLive.Index
    live "/agents/new", AgentLive.New
    live "/agents/:id", AgentLive.Show
    live "/agents/:id/edit", AgentLive.Edit
  end

  scope "/api", CymphoWeb do
    pipe_through :api

    resources "/users", UserController, only: [:index, :show, :create, :update, :delete]
    patch "/users/:id/notification-prefs", UserController, :update_notification_prefs

    post "/telegram/webhook", TelegramController, :webhook
    post "/github/webhook", GithubController, :webhook

    resources "/routines", RoutineController, only: [:index, :show, :create, :update, :delete]
    patch "/routines/:id/pause", RoutineController, :pause
    patch "/routines/:id/resume", RoutineController, :resume
    patch "/routines/:id/archive", RoutineController, :archive

    resources "/routines/:routine_id/triggers", RoutineTriggerController,
      only: [:index, :create, :show, :update, :delete],
      name: "routine_trigger"

    post "/routine-triggers/:id/rotate-secret", RoutineTriggerController, :rotate_secret

    post "/routine-triggers/:public_id/fire", RoutineTriggerController, :fire

    post "/issues/:issue_id/execution-policy/assign", IssueExecutionPolicyController, :assign
    post "/issues/:issue_id/execution-policy/decide", IssueExecutionPolicyController, :decide
  end

  scope "/api", CymphoWeb do
    pipe_through :api
    pipe_through CymphoWeb.Plugs.AgentAuth

    get "/agents/:id/inbox", AgentController, :inbox
    patch "/agents/:id/status", AgentController, :update_status
  end
end
