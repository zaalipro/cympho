defmodule CymphoWeb.IssueLabelController do
  use CymphoWeb, :controller
  alias Cympho.Issues
  alias Cympho.Labels
  action_fallback CymphoWeb.FallbackController

  def index(conn, %{"issue_id" => issue_id}) do
    company_id = conn.assigns.current_company.id

    with {:ok, issue} <- Issues.get_company_issue(company_id, issue_id),
         do: render(conn, :index, labels: issue.labels)
  end

  def add(conn, %{"issue_id" => issue_id, "label_id" => label_id}) do
    company_id = conn.assigns.current_company.id

    with {:ok, issue} <- Issues.get_company_issue(company_id, issue_id),
         {:ok, label} <- Labels.get_company_label(company_id, label_id),
         {:ok, issue} <- Issues.add_label_to_issue(issue, label) do
      render(conn, :index, labels: issue.labels)
    end
  end

  def remove(conn, %{"issue_id" => issue_id, "label_id" => label_id}) do
    company_id = conn.assigns.current_company.id

    with {:ok, issue} <- Issues.get_company_issue(company_id, issue_id),
         {:ok, label} <- Labels.get_company_label(company_id, label_id),
         {:ok, _issue} <- Issues.remove_label_from_issue(issue, label) do
      send_resp(conn, :no_content, "")
    end
  end

  def set(conn, %{"issue_id" => issue_id, "label_ids" => label_ids}) do
    company_id = conn.assigns.current_company.id

    with {:ok, issue} <- Issues.get_company_issue(company_id, issue_id),
         :ok <- ensure_labels_in_company(label_ids, company_id),
         {:ok, issue} <- Issues.set_issue_labels(issue, label_ids) do
      render(conn, :index, labels: issue.labels)
    end
  end

  defp ensure_labels_in_company(label_ids, company_id) when is_list(label_ids) do
    Enum.reduce_while(label_ids, :ok, fn id, :ok ->
      case Labels.get_company_label(company_id, id) do
        {:ok, _} -> {:cont, :ok}
        {:error, :not_found} -> {:halt, {:error, :not_found}}
      end
    end)
  end

  defp ensure_labels_in_company(_, _), do: {:error, :not_found}
end
