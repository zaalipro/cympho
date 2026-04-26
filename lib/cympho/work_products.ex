defmodule Cympho.WorkProducts do
  import Ecto.Query, warn: false
  alias Cympho.Repo
  alias Cympho.WorkProducts.IssueWorkProduct
  alias Cympho.Activities

  def list_work_products(issue_id) do
    IssueWorkProduct
    |> where(issue_id: ^issue_id)
    |> order_by(desc: :inserted_at)
    |> preload([:created_by_agent, :attachment])
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
        work_product = Repo.preload(work_product, [:created_by_agent, :attachment])

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

        Phoenix.PubSub.broadcast(
          Cympho.PubSub,
          "issues",
          {:work_product_created, work_product}
        )

        {:ok, work_product}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def update_work_product(%IssueWorkProduct{} = work_product, attrs) do
    case work_product
         |> IssueWorkProduct.changeset(attrs)
         |> Repo.update() do
      {:ok, updated} ->
        updated = Repo.preload(updated, [:created_by_agent, :attachment])

        Phoenix.PubSub.broadcast(
          Cympho.PubSub,
          "issues",
          {:work_product_updated, updated}
        )

        {:ok, updated}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def delete_work_product(%IssueWorkProduct{} = work_product) do
    case Repo.delete(work_product) do
      {:ok, _} ->
        Phoenix.PubSub.broadcast(
          Cympho.PubSub,
          "issues",
          {:work_product_deleted, work_product.issue_id}
        )

        :ok

      {:error, changeset} ->
        {:error, changeset}
    end
  end
end
