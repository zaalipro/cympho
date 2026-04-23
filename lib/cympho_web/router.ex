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
    live "/approvals", ApprovalLive.Index
    live "/approvals/:id", ApprovalLive.Show
    live "/agents", AgentLive.Index
    live "/agents/new", AgentLive.New
    live "/agents/:id", AgentLive.Show
    live "/agents/:id/edit", AgentLive.Edit
  end

  scope "/api", CymphoWeb do
    pipe_through :api

    resources "/users", UserController, only: [:index, :show, :create, :update, :delete]
    patch "/users/:id/notification-prefs", UserController, :update_notification_prefs

    get "/agents/:id/inbox", AgentController, :inbox
    patch "/agents/:id/status", AgentController, :update_status

    resources "/issues", IssueController, only: [:create, :show]

    post "/telegram/webhook", TelegramController, :webhook
    post "/github/webhook", GithubController, :webhook

    resources "/labels", LabelController, only: [:index, :show, :create, :update, :delete]
    resources "/approvals", ApprovalController, only: [:index, :show, :create, :update]

    get "/issues/:issue_id/labels", IssueLabelController, :index
    post "/issues/:issue_id/labels", IssueLabelController, :add
    delete "/issues/:issue_id/labels/:label_id", IssueLabelController, :remove
    put "/issues/:issue_id/labels", IssueLabelController, :set

    get "/issues/:issue_id/attachments", AttachmentController, :index
    post "/issues/:issue_id/attachments", AttachmentController, :create
    get "/attachments/:id", AttachmentController, :show
    get "/attachments/:id/download", AttachmentController, :download
    delete "/attachments/:id", AttachmentController, :delete
  end
    resources "/approvals", ApprovalController, only: [:index, :show, :create, :update]
end
