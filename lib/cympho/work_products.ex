defmodule Cympho.WorkProducts do
  import Ecto.Query, warn: false
  alias Cympho.Repo
  alias Cympho.WorkProducts.IssueWorkProduct
  alias Cympho.Activities

  def list_work_products(issue_id) do
    IssueWorkProduct
    |> where(issue_id: ^issue_id)
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

  def get_work_product!(id) do
    Repo.get!(IssueWorkProduct, id)
  end

  def get_work_product(id) do
    case Repo.get(IssueWorkProduct, id) do
      nil -> {:error, :not_found}
      work_product -> {:ok, work_product}
    end
  end

  def create_work_product(attrs) do
    case %IssueWorkProduct{}
         |> IssueWorkProduct.changeset(attrs)
         |> Repo.insert() do
      {:ok, work_product} ->
        Activities.log_activity(%{
          issue_id: work_product.issue_id,
          actor_type: "agent",
          actor_id: attrs[:created_by_agent_id] || attrs["created_by_agent_id"],
          action: "work_product_created",
          metadata: %{
            work_product_id: work_product.id,
            kind: work_product.kind,
            title: work_product.title
          }
        })

        {:ok, work_product}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def update_work_product(%IssueWorkProduct{} = work_product, attrs) do
    work_product
    |> IssueWorkProduct.changeset(attrs)
    |> Repo.update()
  end

  def delete_work_product(%IssueWorkProduct{} = work_product) do
    Repo.delete(work_product)
  end
end
