defmodule CymphoWeb.WorkProductController do
  use CymphoWeb, :controller

  alias Cympho.WorkProducts
  alias Cympho.WorkProducts.IssueWorkProduct

  action_fallback CymphoWeb.FallbackController

  def index(conn, %{"issue_id" => issue_id}) do
    work_products = WorkProducts.list_work_products(issue_id)
    render(conn, :index, work_products: work_products)
  end

  def create(conn, %{"issue_id" => issue_id} = params) do
    attrs =
      params
      |> Map.take(["kind", "title", "description", "payload", "url", "metadata", "attachment_id"])
      |> Map.put("issue_id", issue_id)
      |> maybe_put_agent_id(conn)

    with {:ok, %IssueWorkProduct{} = work_product} <- WorkProducts.create_work_product(attrs) do
      conn
      |> put_status(:created)
      |> render(:show, work_product: work_product)
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, %IssueWorkProduct{} = work_product} <- WorkProducts.get_work_product(id) do
      render(conn, :show, work_product: work_product)
    end
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, %IssueWorkProduct{} = work_product} <- WorkProducts.get_work_product(id) do
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
    with {:ok, %IssueWorkProduct{} = work_product} <- WorkProducts.get_work_product(id) do
      with {:ok, _} <- WorkProducts.delete_work_product(work_product) do
        send_resp(conn, :no_content, "")
      end
    end
  end

  defp maybe_put_agent_id(attrs, conn) do
    case conn.assigns[:current_agent] do
      %{id: agent_id} -> Map.put(attrs, "created_by_agent_id", agent_id)
      _ -> attrs
    end
  end
end
