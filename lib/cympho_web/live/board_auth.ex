defmodule CymphoWeb.Live.BoardAuth do
  @moduledoc """
  LiveView on_mount hook ensuring only board members can perform governance mutations.

  Assigns :is_board_member to the socket for conditional UI rendering.
  Redirects non-board users away with an error flash.
  Blocks all access when no board members exist for the company.
  """

  import Phoenix.LiveView
  import Phoenix.Component
  alias Cympho.Companies
  alias Cympho.GovernanceAuditLogs

  def on_mount(:default, _params, _session, socket) do
    user = socket.assigns[:current_user]
    company = socket.assigns[:current_company]
    company_id = company && company.id

    cond do
      is_nil(user) or is_nil(company_id) ->
        {:cont, assign(socket, :is_board_member, false)}

      not board_members_present?(company_id) ->
        log_denial(user, company_id, "No board members configured")

        {:halt,
         socket
         |> put_flash(
           :error,
           "Governance mutations are blocked until board members are configured."
         )
         |> redirect(to: "/")}

      Companies.is_board_member?(user.id, company_id) ->
        {:cont, assign(socket, :is_board_member, true)}

      true ->
        log_denial(user, company_id, "Board membership required")

        {:halt,
         socket
         |> put_flash(:error, "You must be a board member to access this page.")
         |> redirect(to: "/")}
    end
  end

  defp board_members_present?(company_id) do
    Companies.list_board_members(company_id) != []
  end

  defp log_denial(user, company_id, reason) do
    GovernanceAuditLogs.log_action(
      "guard_denied",
      user,
      "LiveView access denied: #{reason}",
      metadata: %{company_id: company_id}
    )
  end
end
