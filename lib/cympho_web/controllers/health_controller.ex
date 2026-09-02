defmodule CymphoWeb.HealthController do
  use CymphoWeb, :controller

  alias Cympho.Readiness
  alias Cympho.Readiness.Cache

  def show(conn, _params) do
    opts = Application.get_env(:cympho, :readiness, [])
    report = Cache.report(opts)

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_status(Readiness.http_status(report))
    |> json(report)
  end
end
