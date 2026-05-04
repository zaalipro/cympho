defmodule CymphoWeb.Plugs.CompanyAccess do
  @moduledoc """
  Verifies that `current_user` is a member of the company addressed by the
  request. Reads the company id from the path params (`company_id` or `id`)
  and checks `Cympho.Companies.has_access?/2`. Halts 404 on miss so the
  caller can't probe for company existence.

  Use as a controller-level plug after `:api_authenticated`:

      plug CymphoWeb.Plugs.CompanyAccess when action in [...]

  Optionally pass `:require_admin` to require an admin/owner role:

      plug CymphoWeb.Plugs.CompanyAccess, [require_admin: true] when action in [...]
  """

  import Plug.Conn
  alias Cympho.Companies

  def init(opts), do: opts

  def call(conn, opts) do
    require_admin? = Keyword.get(opts, :require_admin, false)
    user = conn.assigns[:current_user]
    company_id = conn.params["company_id"] || conn.params["id"]

    cond do
      is_nil(user) or is_nil(company_id) ->
        not_found(conn)

      not Companies.has_access?(user.id, company_id) ->
        not_found(conn)

      require_admin? and not Companies.admin?(user.id, company_id) ->
        forbidden(conn)

      true ->
        conn
    end
  end

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> Phoenix.Controller.json(%{errors: [%{detail: "Not found"}]})
    |> halt()
  end

  defp forbidden(conn) do
    conn
    |> put_status(:forbidden)
    |> Phoenix.Controller.json(%{errors: [%{detail: "Forbidden"}]})
    |> halt()
  end
end
