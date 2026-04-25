defmodule CymphoWeb.Socket do
  use Phoenix.Socket

  channel "activities:*", CymphoWeb.ActivityChannel
  channel "issue:*", CymphoWeb.IssueChannel

  @impl true
  def connect(_params, socket, _connect_info) do
    {:ok, socket}
  end

  @impl true
  def id(_socket), do: nil
end
