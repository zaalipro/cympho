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
    live "/agents", AgentLive.Index
    live "/agents/new", AgentLive.New
    live "/agents/:id", AgentLive.Show
    live "/agents/:id/edit", AgentLive.Edit
  end

  scope "/api", CymphoWeb do
    pipe_through :api

    resources "/users", UserController, only: [:index, :show, :create, :update, :delete]
    patch "/users/:id/notification-prefs", UserController, :update_notification_prefs
    get "/search", SearchController, :search
    resources "/goals", GoalController, only: [:index, :show, :create, :update, :delete]
    post "/telegram/webhook", TelegramController, :webhook
  end

  scope "/api", CymphoWeb do
    pipe_through :github_webhook

    post "/github/webhook", GithubController, :webhook
  end
end
