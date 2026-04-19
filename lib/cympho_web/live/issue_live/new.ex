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

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      New Issue
      <:actions>
        <.link navigate={~p"/issues"} class="phx-btn-secondary">
          Cancel
        </.link>
      </:actions>
    </.header>

    <div class="issue-form">
      <.simple_form :let={f} for={@changeset} phx-submit="save">
        <.input field={f[:title]} label="Title" />
        <.input field={f[:description]} label="Description" type="textarea" />

        <div class="form-group">
          <label>Status</label>
          <select name="issue[status]">
            <option value="open">Open</option>
            <option value="in_progress">In Progress</option>
            <option value="closed">Closed</option>
          </select>
        </div>

        <div class="form-group">
          <label>Priority</label>
          <select name="issue[priority]">
            <option value="low">Low</option>
            <option value="medium">Medium</option>
            <option value="high">High</option>
          </select>
        </div>

        <.button type="submit">Create Issue</.button>
      </.simple_form>
    </div>
    """
  end
end
