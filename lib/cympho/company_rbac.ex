defmodule Cympho.CompanyRBAC do
  @moduledoc """
  Central company-role policy for human users.

  Board membership and other capability checks remain additional gates; they
  never make the read-only `viewer` role writable.
  """

  alias Cympho.Companies

  @roles ~w(owner admin member viewer)

  @type access :: :read | :write | :admin | :owner

  def roles, do: @roles

  def allowed?(role, :read) when role in @roles, do: true
  def allowed?(role, :write) when role in ~w(owner admin member), do: true
  def allowed?(role, :admin) when role in ~w(owner admin), do: true
  def allowed?("owner", :owner), do: true
  def allowed?(_role, _access), do: false

  def authorize(user_id, company_id, access)
      when is_binary(user_id) and is_binary(company_id) do
    user_id
    |> Companies.get_role(company_id)
    |> authorize_role(access)
  end

  def authorize(_user_id, _company_id, _access), do: {:error, :forbidden}

  def authorize_role(role, access) do
    if allowed?(role, access), do: :ok, else: {:error, :forbidden}
  end

  @doc """
  Returns whether a membership may perform company-management actions.

  Owners and admins qualify by role. A board seat also qualifies a regular
  member, but never promotes a read-only viewer into a writable role.
  """
  def manager?(user_id, company_id)
      when is_binary(user_id) and is_binary(company_id) do
    case Companies.get_membership(user_id, company_id) do
      %{role: role, is_board_member: board_member?} ->
        allowed?(role, :write) and (allowed?(role, :admin) or board_member? == true)

      _ ->
        false
    end
  end

  def manager?(_user_id, _company_id), do: false
end
