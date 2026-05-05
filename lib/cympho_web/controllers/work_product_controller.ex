defmodule CymphoWeb.WorkProductController do
  use CymphoWeb, :controller

  alias Cympho.{WorkProducts, Issues}
  alias Cympho.WorkProducts.IssueWorkProduct

  action_fallback CymphoWeb.FallbackController

  def index(conn, %{"issue_id" => issue_id}) do
    with {:ok, issue} <- scoped_issue(conn, issue_id) do
      work_products = WorkProducts.list_work_products(issue.id)
      render(conn, :index, work_products: work_products)
    end
  end

  def create(conn, %{"issue_id" => issue_id} = params) do
    with {:ok, issue} <- scoped_issue(conn, issue_id) do
      attrs =
        params
        |> Map.take([
          "kind",
          "title",
          "description",
          "payload",
          "url",
          "metadata",
          "attachment_id"
        ])
        |> Map.put("issue_id", issue.id)
        |> maybe_put_agent_id(conn)

      with {:ok, %IssueWorkProduct{} = work_product} <- WorkProducts.create_work_product(attrs) do
        conn
        |> put_status(:created)
        |> render(:show, work_product: work_product)
      end
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, %IssueWorkProduct{} = work_product} <- WorkProducts.get_work_product(id),
         :ok <- enforce_company(conn, work_product) do
      render(conn, :show, work_product: work_product)
    end
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, %IssueWorkProduct{} = work_product} <- WorkProducts.get_work_product(id),
         :ok <- enforce_company(conn, work_product) do
      attrs =
        Map.take(params, [
          "kind",
          "title",
          "description",
          "payload",
          "url",
          "metadata",
          "attachment_id"
        ])

      with {:ok, %IssueWorkProduct{} = updated} <-
             WorkProducts.update_work_product(work_product, attrs) do
        render(conn, :show, work_product: updated)
      end
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, %IssueWorkProduct{} = work_product} <- WorkProducts.get_work_product(id),
         :ok <- enforce_company(conn, work_product),
         :ok <- WorkProducts.delete_work_product(work_product) do
      send_resp(conn, :no_content, "")
    end
  end

  defp scoped_issue(conn, issue_id) do
    Issues.get_company_issue(conn.assigns.current_company.id, issue_id)
  end

  defp enforce_company(conn, %IssueWorkProduct{issue_id: issue_id}) do
    case scoped_issue(conn, issue_id) do
      {:ok, _} -> :ok
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  defp maybe_put_agent_id(attrs, conn) do
    case conn.assigns[:current_agent] do
      %{id: agent_id} -> Map.put(attrs, "created_by_agent_id", agent_id)
      _ -> attrs
    end
  end
end
