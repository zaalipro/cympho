defmodule CymphoWeb.IssueLive.New do
  use CymphoWeb, :live_view
  alias Cympho.Issues
  alias Cympho.Issues.Issue

  @impl true
  def mount(_params, _session, socket) do
    changeset = Issues.change_issue(%Issue{})
    {:ok, assign(socket, changeset: changeset)}
  end

  @impl true
  def handle_event("save", %{"issue" => issue_params}, socket) do
    case Issues.create_issue(issue_params) do
      {:ok, _issue} ->
        {:noreply, push_navigate(socket, to: ~p"/issues")}

      {:error, changeset} ->
        {:noreply, assign(socket, changeset: changeset)}
    end
  end
end