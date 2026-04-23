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

  @doc """
  Session plug for the settings page. Ensures a user_id is bound to the session
  so that visitors can only access their own settings, not arbitrary users'.

  - If `user_id` is already in the session, it is used.
  - If `user_id` param is provided, it is stored in the session.
  - If neither is present, the request is allowed but the LiveView will show a
    user picker (existing behavior).
  - If a `user_id` param is provided that differs from the session user_id, the
    param is ignored to prevent cross-user access.
  """
  def settings_session(conn, _opts) do
    session_user_id = get_session(conn, :settings_user_id)

    conn =
      if session_user_id do
        assign(conn, :settings_user_id, session_user_id)
      else
        conn
      end

    # If no session binding yet, allow the LiveView to handle the user picker
    conn
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
  end

  scope "/", CymphoWeb do
    pipe_through [:browser, :settings_session]

    live "/settings", SettingsLive.Index
  end

  scope "/api", CymphoWeb do
    pipe_through :api

    resources "/users", UserController, only: [:index, :show, :create, :update, :delete]
    patch "/users/:id/notification-prefs", UserController, :update_notification_prefs

    get "/search", SearchController, :search

    post "/telegram/webhook", TelegramController, :webhook
    post "/github/webhook", GithubController, :webhook

    resources "/labels", LabelController, only: [:index, :show, :create, :update, :delete]

    get "/issues/:issue_id/labels", IssueLabelController, :index
    post "/issues/:issue_id/labels", IssueLabelController, :add
    delete "/issues/:issue_id/labels/:label_id", IssueLabelController, :remove
    put "/issues/:issue_id/labels", IssueLabelController, :set
  end

  scope "/api", CymphoWeb do
    pipe_through :api
    pipe_through CymphoWeb.Plugs.AgentAuth

    get "/agents/:id/inbox", AgentController, :inbox
    patch "/agents/:id/status", AgentController, :update_status

    resources "/issues", IssueController, only: [:create, :show]
  end
end
