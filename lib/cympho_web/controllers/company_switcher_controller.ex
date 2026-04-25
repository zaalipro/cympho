defmodule CymphoWeb.CompanySwitcherController do
  use CymphoWeb, :controller

  alias Cympho.Companies

  def switch(conn, %{"id" => company_id}) do
    user = conn.assigns[:current_user]

    cond do
      is_nil(user) ->
        redirect(conn, to: "/")

      true ->
        # Verify the user has access to this company
        if Companies.has_access?(user.id, company_id) do
          # Update the session with the new company_id
          conn
          |> put_session(:company_id, company_id)
          |> redirect(to: get_back_path(conn))
        else
          redirect(conn, to: "/")
        end
    end
  end

  defp get_back_path(conn) do
    # Get the return path from query params or referer, default to dashboard
    case get_in(conn.params, ["return_to"]) do
      nil -> get_req_header(conn, "referer") |> List.first("/") || "/"
      path -> path
    end
  end
end
