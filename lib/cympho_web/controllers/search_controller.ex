defmodule CymphoWeb.SearchController do
  use CymphoWeb, :controller
  alias Cympho.Search
  action_fallback CymphoWeb.FallbackController

  def search(conn, %{"q" => q}) when is_binary(q) and byte_size(q) > 0 do
    results = Search.search(q)
    render(conn, :results, results: results)
  end

  def search(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> put_view(json: CymphoWeb.ErrorJSON)
    |> render(:error, message: "Missing or empty query parameter 'q'")
  end
end
