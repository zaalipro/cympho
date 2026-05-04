defmodule CymphoWeb.Plugs.UserAuth do
  @moduledoc """
  Authenticates JSON API requests using a Bearer JWT issued by `Cympho.UserAuthJWT`.

  Assigns:
    - `:current_user` — the User struct
    - `:current_company` — a Company the user is a member of
    - `:user_companies` — list of Company structs the user is a member of

  Company resolution order: `x-company-id` header, JWT `company_id` claim, the
  user's default `company_id`, then the first membership. Halts 403 if the user
  is not a member of the resolved company. Halts 401 on missing/invalid token.
  """

  import Plug.Conn
  import Ecto.Query, only: [from: 2]
  alias Cympho.UserAuthJWT
  alias Cympho.Users
  alias Cympho.Repo

  def init(opts), do: opts

  def call(conn, _opts) do
    with {:ok, token} <- bearer_token(conn),
         {:ok, claims} <- UserAuthJWT.verify_token(token),
         {:ok, user_id} <- UserAuthJWT.get_user_id(claims),
         {:ok, user} <- Users.get_user(user_id) do
      companies = list_user_companies(user.id)

      case resolve_company(conn, user, claims, companies) do
        {:ok, company} ->
          conn
          |> assign(:current_user, user)
          |> assign(:user_companies, companies)
          |> assign(:current_company, company)

        {:error, :no_companies} ->
          unauthorized(conn, "User has no company memberships")

        {:error, :not_a_member} ->
          forbidden(conn, "Not a member of the requested company")
      end
    else
      _ -> unauthorized(conn, "Authentication required")
    end
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when byte_size(token) > 0 -> {:ok, token}
      _ -> {:error, :no_token}
    end
  end

  defp list_user_companies(user_id) do
    Repo.all(
      from(m in Cympho.Companies.CompanyMembership,
        where: m.user_id == ^user_id,
        preload: :company
      )
    )
    |> Enum.map(& &1.company)
  end

  defp resolve_company(_conn, _user, _claims, []), do: {:error, :no_companies}

  defp resolve_company(conn, user, claims, companies) do
    requested =
      case get_req_header(conn, "x-company-id") do
        [id | _] when is_binary(id) and byte_size(id) > 0 -> id
        _ -> claims["company_id"] || user.company_id
      end

    cond do
      is_nil(requested) ->
        {:ok, List.first(companies)}

      company = Enum.find(companies, &(&1.id == requested)) ->
        {:ok, company}

      true ->
        {:error, :not_a_member}
    end
  end

  defp unauthorized(conn, message) do
    conn
    |> put_status(:unauthorized)
    |> Phoenix.Controller.json(%{errors: [%{detail: message}]})
    |> halt()
  end

  defp forbidden(conn, message) do
    conn
    |> put_status(:forbidden)
    |> Phoenix.Controller.json(%{errors: [%{detail: message}]})
    |> halt()
  end
end
