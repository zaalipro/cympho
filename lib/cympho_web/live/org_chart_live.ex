defmodule CymphoWeb.OrgChartLive do
  use CymphoWeb, :live_view
  def mount(_params, _session, socket), do: {:ok, socket}
  def render(assigns), do: ~H"<div></div>"
end
