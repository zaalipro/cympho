defmodule CymphoWeb.IssueLabelController do
  use CymphoWeb, :controller

  alias Cympho.Issues
  alias Cympho.Labels
  alias Cympho.Repo

  action_fallback CymphoWeb.FallbackController

  def index(conn, %{"issue_id" => issue_id}) do
    with {:ok, issue} <- Issues.get_issue(issue_id) do
      labels = Labels.list_labels_for_issue(issue)
      json(conn, %{data: Enum.map(labels, &CymphoWeb.LabelJSON.label_data/1)})
    end
  end

  def add(conn, %{"issue_id" => issue_id, "label_id" => label_id}) do
    with {:ok, issue} <- Issues.get_issue(issue_id),
         {:ok, label} <- Labels.get_label(label_id),
         {:ok, _issue} <- Labels.add_label_to_issue(issue, label) do
      send_resp(conn, :no_content, "")
    end
  end

  def remove(conn, %{"issue_id" => issue_id, "label_id" => label_id}) do
    with {:ok, issue} <- Issues.get_issue(issue_id),
         {:ok, label} <- Labels.get_label(label_id),
         {:ok, _issue} <- Labels.remove_label_from_issue(issue, label) do
      send_resp(conn, :no_content, "")
    end
  end

  def set(conn, %{"issue_id" => issue_id, "label_ids" => label_ids}) do
    with {:ok, issue} <- Issues.get_issue(issue_id),
         {:ok, updated} <- Labels.set_issue_labels(issue, label_ids) do
      labels = Labels.list_labels_for_issue(updated)
      json(conn, %{data: Enum.map(labels, &CymphoWeb.LabelJSON.label_data/1)})
    end
  end
end
