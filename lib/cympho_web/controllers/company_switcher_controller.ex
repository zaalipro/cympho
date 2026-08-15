defmodule CymphoWeb.CompanySwitcherController do
  use CymphoWeb, :controller

  alias Cympho.Companies
  alias Cympho.Users

  def switch(conn, %{"id" => company_id}) do
    user = conn.assigns[:current_user] || current_session_user(conn)

    cond do
      is_nil(user) ->
        redirect(conn, to: "/login")

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

  defp current_session_user(conn) do
    case get_session(conn, :user_id) do
      nil ->
        nil

      user_id ->
        case Users.get_user(user_id) do
          {:ok, user} -> user
          {:error, :not_found} -> nil
        end
    end
  end

  defp get_back_path(conn) do
    # Get the return path from query params or referer, default to dashboard
    return_to = get_in(conn.params, ["return_to"])

    path =
      case return_to do
        nil -> get_req_header(conn, "referer") |> List.first("/") || "/"
        path -> path
      end

    # Validate the path is safe - only allow relative paths starting with /
    if is_safe_path?(path) do
      path
    else
      # Fallback to dashboard if path is unsafe
      "/"
    end
  end

  defp is_safe_path?(path) when is_binary(path) do
    # Normalize to lowercase for case-insensitive protocol check
    path = String.downcase(path)
    # Must start with / and not contain dangerous protocols.
    #
    # "//host" and "/\host" also start with "/" but are protocol-relative URLs
    # pointing off-site. Phoenix's redirect/2 refuses them (validate_local_url/1
    # raises), so letting them through here turned a crafted return_to into a
    # 500 rather than a redirect — still a crash worth closing here.
    not String.starts_with?(path, ["//", "/\\"]) &&
      String.starts_with?(path, "/") &&
      !String.contains?(path, ["javascript:", "data:", "vbscript:", "file:"]) &&
      !String.contains?(path, ["\n", "\r", "\t"])
  end

  defp is_safe_path?(_), do: false
end
