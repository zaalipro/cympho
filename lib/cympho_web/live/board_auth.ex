defmodule CymphoWeb.Live.BoardAuth do
  @moduledoc """
  LiveView on_mount hook ensuring only board members can perform governance mutations.

  Assigns :is_board_member to the socket for conditional UI rendering.
  """

  import Phoenix.LiveView
  import Phoenix.Component
  alias Cympho.Companies

  def on_mount(:default, _params, _session, socket) do
    user = socket.assigns[:current_user]
    company_id = socket.assigns[:current_company_id]

    is_board =
      if user && company_id do
        Companies.is_board_member?(user.id, company_id)
      else
        false
      end

    {:cont, assign(socket, :is_board_member, is_board)}
  end
end
