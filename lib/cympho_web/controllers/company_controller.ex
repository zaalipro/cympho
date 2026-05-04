defmodule CymphoWeb.CompanyController do
  use CymphoWeb, :controller

  alias Cympho.Companies

  action_fallback CymphoWeb.FallbackController

  plug CymphoWeb.Plugs.CompanyAccess
       when action in [
              :show,
              :update,
              :delete,
              :update_governance_config,
              :list_members,
              :list_invites,
              :list_join_requests,
              :create_join_request,
              :export
            ]

  plug CymphoWeb.Plugs.CompanyAccess,
       [require_admin: true]
       when action in [
              :add_member,
              :remove_member,
              :create_invite,
              :revoke_invite,
              :approve_join_request,
              :reject_join_request
            ]

  def index(conn, _params) do
    user = conn.assigns.current_user

    companies =
      Companies.list_memberships_for_user(user.id)
      |> Enum.map(& &1.company)

    json(conn, %{data: companies})
  end

  def show(conn, %{"id" => id}) do
    company = Companies.get_company!(id)
    json(conn, %{data: company})
  end

  def create(conn, %{"company" => company_params}) do
    user = conn.assigns.current_user

    case Companies.create_company(company_params) do
      {:ok, company} ->
        # The creator becomes the first owner.
        Companies.create_membership(%{
          user_id: user.id,
          company_id: company.id,
          role: "owner"
        })

        conn |> put_status(:created) |> json(%{data: company})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: translate_errors(changeset)})
    end
  end

  def update(conn, %{"id" => id, "company" => company_params}) do
    company = Companies.get_company!(id)

    case Companies.update_company(company, company_params) do
      {:ok, company} -> json(conn, %{data: company})
      {:error, changeset} -> error_changeset(conn, changeset)
    end
  end

  def update_governance_config(conn, %{"id" => id, "governance_config" => config_params}) do
    company = Companies.get_company!(id)

    case Companies.update_company(company, %{governance_config: config_params}) do
      {:ok, company} -> json(conn, %{data: company})
      {:error, changeset} -> error_changeset(conn, changeset)
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
    json(conn, %{data: Companies.list_memberships(company_id)})
  end

  def add_member(conn, %{"company_id" => company_id, "user_id" => user_id, "role" => role}) do
    case Companies.create_membership(%{
           company_id: company_id,
           user_id: user_id,
           role: role
         }) do
      {:ok, m} -> conn |> put_status(:created) |> json(%{data: m})
      {:error, changeset} -> error_changeset(conn, changeset)
    end
  end

  def remove_member(conn, %{"company_id" => company_id, "user_id" => user_id}) do
    case Companies.get_membership(user_id, company_id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Membership not found"})

      membership ->
        case Companies.delete_membership(membership) do
          {:ok, _} -> send_resp(conn, :no_content, "")
          {:error, changeset} -> error_changeset(conn, changeset)
        end
    end
  end

  # ── Invites ──

  def list_invites(conn, %{"company_id" => company_id}) do
    json(conn, %{data: Companies.list_pending_invites(company_id)})
  end

  def create_invite(conn, %{"company_id" => company_id, "invite" => invite_params}) do
    attrs =
      Map.merge(invite_params, %{
        "company_id" => company_id,
        "inviter_id" => conn.assigns.current_user.id
      })

    case Companies.create_invite(attrs) do
      {:ok, invite} -> conn |> put_status(:created) |> json(%{data: invite})
      {:error, changeset} -> error_changeset(conn, changeset)
    end
  end

  def accept_invite(conn, %{"token" => token}) do
    case Companies.accept_invite(token, conn.assigns.current_user.id) do
      {:ok, _} -> json(conn, %{data: %{accepted: true}})
      {:error, reason} -> conn |> put_status(:bad_request) |> json(%{error: to_string(reason)})
    end
  end

  def revoke_invite(conn, %{"company_id" => company_id, "invite_id" => invite_id}) do
    invite = Cympho.Repo.get(Cympho.Companies.CompanyInvite, invite_id)

    cond do
      is_nil(invite) ->
        conn |> put_status(:not_found) |> json(%{error: "Invite not found"})

      invite.company_id != company_id ->
        conn |> put_status(:not_found) |> json(%{error: "Invite not found"})

      true ->
        case Companies.revoke_invite(invite) do
          {:ok, _} -> json(conn, %{data: %{revoked: true}})
          {:error, changeset} -> error_changeset(conn, changeset)
        end
    end
  end

  # ── Join Requests ──

  def list_join_requests(conn, %{"company_id" => company_id}) do
    json(conn, %{data: Companies.list_pending_join_requests(company_id)})
  end

  def create_join_request(conn, %{"company_id" => company_id} = params) do
    case Companies.create_join_request(%{
           company_id: company_id,
           user_id: conn.assigns.current_user.id,
           message: params["message"]
         }) do
      {:ok, request} -> conn |> put_status(:created) |> json(%{data: request})
      {:error, changeset} -> error_changeset(conn, changeset)
    end
  end

  def approve_join_request(conn, %{"company_id" => company_id, "request_id" => request_id}) do
    handle_join_request(conn, company_id, request_id, &Companies.approve_join_request/2,
      key: :approved
    )
  end

  def reject_join_request(conn, %{"company_id" => company_id, "request_id" => request_id}) do
    handle_join_request(conn, company_id, request_id, &Companies.reject_join_request/2,
      key: :rejected
    )
  end

  # ── Export / Import ──

  def export(conn, %{"company_id" => company_id}) do
    json(conn, %{data: Companies.export_company(company_id)})
  end

  def import_company(conn, %{"company" => company_data}) do
    slug_strategy =
      case conn.params["slug_strategy"] do
        "fail" -> :fail
        _ -> :suffix
      end

    case Companies.import_company(company_data, slug_strategy: slug_strategy) do
      {:ok, %{company: company}} ->
        # Creator becomes owner of the imported company.
        Companies.create_membership(%{
          user_id: conn.assigns.current_user.id,
          company_id: company.id,
          role: "owner"
        })

        conn |> put_status(:created) |> json(%{data: company})

      {:error, changeset} when is_struct(changeset) ->
        error_changeset(conn, changeset)

      {:error, reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: to_string(reason)})
    end
  end

  # ── Helpers ──

  defp handle_join_request(conn, company_id, request_id, fun, opts) do
    request = Cympho.Repo.get(Cympho.Companies.JoinRequest, request_id)

    cond do
      is_nil(request) ->
        conn |> put_status(:not_found) |> json(%{error: "Join request not found"})

      request.company_id != company_id ->
        conn |> put_status(:not_found) |> json(%{error: "Join request not found"})

      true ->
        case fun.(request, conn.assigns.current_user.id) do
          {:ok, _} -> json(conn, %{data: %{Keyword.fetch!(opts, :key) => true}})
          {:error, changeset} -> error_changeset(conn, changeset)
        end
    end
  end

  defp error_changeset(conn, changeset) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: translate_errors(changeset)})
  end

  defp translate_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
