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
      <form phx-submit="save">
        <div class="form-group">
          <label for="issue_title">Title</label>
          <input
            type="text"
            id="issue_title"
            name="issue[title]"
            value={@changeset.params["title"]}
            required
          />
        </div>

        <div class="form-group">
          <label for="issue_description">Description</label>
          <textarea id="issue_description" name="issue[description]" required><%= @changeset.params["description"] %></textarea>
        </div>

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

        <button type="submit" class="phx-btn">Create Issue</button>
      </form>
    </div>
    """
  end
end
