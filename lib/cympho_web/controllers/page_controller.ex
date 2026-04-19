defmodule CymphoWeb.PageController do
  use CymphoWeb, :controller

  def home(conn, _params) do
    redirect(conn, to: ~p"/issues")
  end
end
