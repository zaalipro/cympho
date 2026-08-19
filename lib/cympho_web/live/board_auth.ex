defmodule CymphoWeb.Live.BoardAuth do
  @moduledoc """
  LiveView on_mount hook ensuring only board members can perform governance mutations.

  Assigns :is_board_member to the socket for conditional UI rendering.
  Redirects non-board users away with an error flash.
  Blocks all access when no board members exist for the company.
  """

  import Phoenix.LiveView
  import Phoenix.Component
  alias Cympho.CompanyRBAC
  alias Cympho.Companies
  alias Cympho.GovernanceAuditLogs

  def on_mount(:default, _params, _session, socket) do
    case authorize(socket) do
      {:ok, socket} ->
        socket =
          attach_fresh_hooks(socket)

        {:cont, socket}

      {:error, socket} ->
        {:halt, socket}
    end
  end

  # Direct unit tests construct a bare Socket without router lifecycle state.
  # Real routed LiveViews always carry both fields and receive all fresh checks.
  defp attach_fresh_hooks(%{router: router, private: %{lifecycle: _}} = socket)
       when not is_nil(router) do
    socket
    |> attach_hook(:fresh_board_event, :handle_event, &authorize_event/3)
    |> attach_hook(:fresh_board_params, :handle_params, &authorize_params/3)
    |> attach_hook(:fresh_board_info, :handle_info, &authorize_info/2)
  end

  defp attach_fresh_hooks(socket), do: socket

  defp authorize_event(_event, _params, socket), do: authorize_hook(socket)
  defp authorize_params(_params, _url, socket), do: authorize_hook(socket)
  defp authorize_info(_message, socket), do: authorize_hook(socket)

  defp authorize_hook(socket) do
    case authorize(socket) do
      {:ok, socket} -> {:cont, socket}
      {:error, socket} -> {:halt, socket}
    end
  end

  defp authorize(socket) do
    user = socket.assigns[:current_user]
    company = socket.assigns[:current_company]
    company_id = company && company.id

    cond do
      is_nil(user) or is_nil(company_id) ->
        {:ok, assign(socket, :is_board_member, false)}

      not board_members_present?(company_id) ->
        deny(
          socket,
          user,
          company_id,
          "No board members configured",
          "Governance mutations are blocked until board members are configured."
        )

      not CompanyRBAC.allowed?(Companies.get_role(user.id, company_id), :write) ->
        deny(
          socket,
          user,
          company_id,
          "Writable company role required",
          "Your company role cannot perform governance mutations."
        )

      Companies.is_board_member?(user.id, company_id) ->
        {:ok, assign(socket, :is_board_member, true)}

      true ->
        deny(
          socket,
          user,
          company_id,
          "Board membership required",
          "You must be a board member to access this page."
        )
    end
  end

  defp deny(socket, user, company_id, reason, message) do
    log_denial(user, company_id, reason)

    {:error,
     socket
     |> assign(:is_board_member, false)
     |> put_flash(:error, message)
     |> redirect(to: "/")}
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
