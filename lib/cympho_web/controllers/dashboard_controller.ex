defmodule CymphoWeb.DashboardController do
  use CymphoWeb, :controller

  alias Cympho.Dashboard

  action_fallback CymphoWeb.FallbackController

  def index(conn, _params) do
    company_id = conn.assigns.current_company.id
    json(conn, %{data: Dashboard.summary(company_id)})
  end
end
