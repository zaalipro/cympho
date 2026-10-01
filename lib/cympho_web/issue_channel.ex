defmodule CymphoWeb.IssueChannel do
  @moduledoc """
  Channel for issue-specific WebSocket subscriptions.
  """

  use CymphoWeb, :channel

  alias Cympho.Companies
  alias Cympho.Issues

  @impl true
  def join("company:" <> rest, _payload, socket) do
    case String.split(rest, ":") do
      [company_id, "issue", issue_id] ->
        with true <- socket.assigns.company_id == company_id,
             true <-
               socket.assigns[:auth_method] != :session or
                 Companies.has_access?(socket.assigns.user_id, company_id),
             {:ok, valid_id} <- Ecto.UUID.cast(issue_id),
             {:ok, _issue} <- Issues.get_company_issue(company_id, valid_id) do
          send(self(), :after_join)
          {:ok, assign(socket, :issue_id, valid_id)}
        else
          _ ->
            {:error, %{reason: "unauthorized"}}
        end

      _ ->
        {:error, %{reason: "invalid_topic"}}
    end
  end

  @impl true
  def join(_, _payload, _socket) do
    {:error, %{reason: "invalid_topic"}}
  end

  @impl true
  def handle_info(:after_join, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_in("ping", _payload, socket) do
    {:reply, {:ok, %{pong: true}}, socket}
  end
end
