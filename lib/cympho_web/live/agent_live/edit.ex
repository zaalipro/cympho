defmodule CymphoWeb.AgentLive.Edit do
  @moduledoc """
  Legacy route. The agent edit form is now embedded in the show LiveView's
  Configuration tab — this LiveView simply redirects to it so old links keep
  working.
  """

  use CymphoWeb, :live_view

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    {:ok, push_navigate(socket, to: ~p"/agents/#{id}?tab=configuration")}
  end

  @impl true
  def render(assigns), do: ~H""
end
