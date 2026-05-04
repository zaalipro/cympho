defmodule CymphoWeb.Live.CompanySwitcherHelper do
  @moduledoc """
  Helper module for LiveViews that need company switching functionality.

  Provides event handlers for opening/closing the company switcher modal
  and switching the current company context.
  """

  import Phoenix.LiveView
  import Phoenix.Component

  @doc """
  Handles the switch_company event to update the current company session.
  Should be called from handle_event/3 in the LiveView.
  """
  def handle_switch_company(params, socket) do
    company_id = params["id"]

    # Update the session with the new company_id
    # This requires a navigate to set the new session value
    {:noreply,
     socket
     |> push_navigate(to: "/?company_id=#{URI.encode_www_form(company_id)}")}
  end

  @doc """
  Assigns the switcher open state to the socket.
  """
  def assign_switcher_state(socket, state \\ false) do
    assign(socket, :company_switcher_open, state)
  end

  @doc """
  Renders the company switcher component with current socket assigns.
  """
  def render_company_switcher(assigns) do
    ~H"""
    <.live_component
      module={CymphoWeb.Components.CompanySwitcher}
      id="company-switcher"
      companies={@user_companies || []}
      current_company_id={if @current_company, do: @current_company.id, else: nil}
      search_query={assigns[:search_query] || ""}
    />
    """
  end
end
