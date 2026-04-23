defmodule CymphoWeb.DashboardController do
  use CymphoWeb, :controller

  alias Cympho.Dashboard

  action_fallback CymphoWeb.FallbackController

  def index(conn, _params) do
    json(conn, %{data: Dashboard.summary()})
  end
end
