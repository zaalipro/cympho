defmodule CymphoWeb.Plugs.CompanyAccess do
  @moduledoc """
  Verifies that `current_user` is a member of the company addressed by the
  request. Reads the company id from the path params (`company_id` or `id`)
  and checks `Cympho.Companies.has_access?/2`. Halts 404 on miss so the
  caller can't probe for company existence.

  Use as a controller-level plug after `:api_authenticated`:

      plug CymphoWeb.Plugs.CompanyAccess when action in [...]

  Pass `require: :manager` for company-management actions. Managers are
  owners/admins or writable-role board members; read-only viewers never gain
  mutation rights from a board flag alone.

      plug CymphoWeb.Plugs.CompanyAccess, [require: :manager] when action in [...]
  """

  import Plug.Conn
  alias Cympho.CompanyRBAC
  alias Cympho.Companies

  def init(opts), do: opts

  def call(conn, opts) do
    required_access =
      Keyword.get(
        opts,
        :require,
        if(Keyword.get(opts, :require_admin, false), do: :admin, else: :read)
      )

    user = conn.assigns[:current_user]
    company_id = conn.path_params["company_id"] || conn.path_params["id"]

    cond do
      is_nil(user) or is_nil(company_id) ->
        not_found(conn)

      not Companies.has_access?(user.id, company_id) ->
        not_found(conn)

      not authorized?(user.id, company_id, required_access) ->
        forbidden(conn)

      true ->
        conn
    end
  end

  defp authorized?(user_id, company_id, :manager),
    do: CompanyRBAC.manager?(user_id, company_id)

  defp authorized?(user_id, company_id, access),
    do: CompanyRBAC.allowed?(Companies.get_role(user_id, company_id), access)

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
