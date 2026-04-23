defmodule CymphoWeb.IssueLabelController do
  use CymphoWeb, :controller
  alias Cympho.Issues
  alias Cympho.Labels
  action_fallback CymphoWeb.FallbackController

  def index(conn, %{"issue_id" => issue_id}) do
    with {:ok, issue} <- Issues.get_issue(issue_id),
         do: render(conn, :index, labels: issue.labels)
  end

  def add(conn, %{"issue_id" => issue_id, "label_id" => label_id}) do
    with {:ok, issue} <- Issues.get_issue(issue_id),
         {:ok, label} <- Labels.get_label(label_id),
         {:ok, issue} <- Issues.add_label_to_issue(issue, label) do
      render(conn, :index, labels: issue.labels)
    end
  end

  def remove(conn, %{"issue_id" => issue_id, "label_id" => label_id}) do
    with {:ok, issue} <- Issues.get_issue(issue_id),
         {:ok, label} <- Labels.get_label(label_id),
         {:ok, _issue} <- Issues.remove_label_from_issue(issue, label) do
      send_resp(conn, :no_content, "")
    end
  end

  def set(conn, %{"issue_id" => issue_id, "label_ids" => label_ids}) do
    with {:ok, issue} <- Issues.get_issue(issue_id),
         {:ok, issue} <- Issues.set_issue_labels(issue, label_ids) do
      render(conn, :index, labels: issue.labels)
    end
  end
end
