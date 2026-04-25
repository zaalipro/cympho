defmodule CymphoWeb.CompanyController do
  use CymphoWeb, :controller

  alias Cympho.Companies

  def index(conn, _params) do
    companies = Companies.list_companies()
    json(conn, %{data: companies})
  end

  def show(conn, %{"id" => id}) do
    company = Companies.get_company!(id)
    json(conn, %{data: company})
  end

  def create(conn, %{"company" => company_params}) do
    case Companies.create_company(company_params) do
      {:ok, company} ->
        conn
        |> put_status(:created)
        json(conn, %{data: company})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: translate_errors(changeset)})
    end
  end

  def update(conn, %{"id" => id, "company" => company_params}) do
    company = Companies.get_company!(id)

    case Companies.update_company(company, company_params) do
      {:ok, company} ->
        json(conn, %{data: company})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: translate_errors(changeset)})
    end
  end

  def delete(conn, %{"id" => id}) do
    company = Companies.get_company!(id)

    case Companies.delete_company(company) do
      {:ok, _} -> send_resp(conn, :no_content, "")
      {:error, changeset} -> json(conn, %{errors: translate_errors(changeset)})
    end
  end

  # ── Memberships ──

  def list_members(conn, %{"company_id" => company_id}) do
    memberships = Companies.list_memberships(company_id)
    json(conn, %{data: memberships})
  end

  def add_member(conn, %{"company_id" => company_id, "user_id" => user_id, "role" => role}) do
    case Companies.create_membership(%{
           company_id: company_id,
           user_id: user_id,
           role: role
         }) do
      {:ok, membership} ->
        conn
        |> put_status(:created)
        |> json(%{data: membership})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: translate_errors(changeset)})
    end
  end

  def remove_member(conn, %{"company_id" => company_id, "user_id" => user_id}) do
    case Companies.get_membership(user_id, company_id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Membership not found"})

      membership ->
        case Companies.delete_membership(membership) do
          {:ok, _} -> send_resp(conn, :no_content, "")
          {:error, changeset} -> json(conn, %{errors: translate_errors(changeset)})
        end
    end
  end

  # ── Invites ──

  def list_invites(conn, %{"company_id" => company_id}) do
    invites = Companies.list_pending_invites(company_id)
    json(conn, %{data: invites})
  end

  def create_invite(conn, %{"company_id" => company_id, "invite" => invite_params}) do
    attrs =
      Map.merge(invite_params, %{
        "company_id" => company_id,
        "inviter_id" => get_current_user_id(conn)
      })

    case Companies.create_invite(attrs) do
      {:ok, invite} ->
        conn
        |> put_status(:created)
        |> json(%{data: invite})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: translate_errors(changeset)})
    end
  end

  def accept_invite(conn, %{"token" => token}) do
    user_id = get_current_user_id(conn)

    case Companies.accept_invite(token, user_id) do
      {:ok, _} ->
        json(conn, %{data: %{accepted: true}})

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: to_string(reason)})
    end
  end

  def revoke_invite(conn, %{"company_id" => _company_id, "invite_id" => invite_id}) do
    invite = Cympho.Repo.get(Cympho.Companies.CompanyInvite, invite_id)

    case invite && Companies.revoke_invite(invite) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Invite not found"})

      {:ok, _} ->
        json(conn, %{data: %{revoked: true}})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: translate_errors(changeset)})
    end
  end

  # ── Join Requests ──

  def list_join_requests(conn, %{"company_id" => company_id}) do
    requests = Companies.list_pending_join_requests(company_id)
    json(conn, %{data: requests})
  end

  def create_join_request(conn, %{"company_id" => company_id}) do
    user_id = get_current_user_id(conn)

    case Companies.create_join_request(%{
           company_id: company_id,
           user_id: user_id,
           message: conn.params["message"]
         }) do
      {:ok, request} ->
        conn
        |> put_status(:created)
        |> json(%{data: request})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: translate_errors(changeset)})
    end
  end

  def approve_join_request(conn, %{"company_id" => _company_id, "request_id" => request_id}) do
    request = Cympho.Repo.get(Cympho.Companies.JoinRequest, request_id)
    reviewer_id = get_current_user_id(conn)

    case request && Companies.approve_join_request(request, reviewer_id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Join request not found"})

      {:ok, _} ->
        json(conn, %{data: %{approved: true}})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: translate_errors(changeset)})
    end
  end

  def reject_join_request(conn, %{"company_id" => _company_id, "request_id" => request_id}) do
    request = Cympho.Repo.get(Cympho.Companies.JoinRequest, request_id)
    reviewer_id = get_current_user_id(conn)

    case request && Companies.reject_join_request(request, reviewer_id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Join request not found"})

      {:ok, _} ->
        json(conn, %{data: %{rejected: true}})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: translate_errors(changeset)})
    end
  end

  # ── Export / Import ──

  def export(conn, %{"company_id" => company_id}) do
    data = Companies.export_company(company_id)
    json(conn, %{data: data})
  end

  def import_company(conn, %{"company" => company_data}) do
    slug_strategy =
      case conn.params["slug_strategy"] do
        "fail" -> :fail
        _ -> :suffix
      end

    case Companies.import_company(company_data, slug_strategy: slug_strategy) do
      {:ok, %{company: company}} ->
        conn
        |> put_status(:created)
        |> json(%{data: company})

      {:error, changeset} when is_struct(changeset) ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: translate_errors(changeset)})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: to_string(reason)})
    end
  end

  # ── Helpers ──

  defp get_current_user_id(conn) do
    # TODO: Extract from session/auth once user auth is wired
    conn.params["user_id"]
  end

  defp translate_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
