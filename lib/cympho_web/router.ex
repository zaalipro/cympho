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
    live "/kanban", KanbanLive.Index
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

    # Public webhook endpoint (no auth, validates via secret header)
    post "/routine-triggers/:public_id/fire", RoutineTriggerController, :fire
  end
end
