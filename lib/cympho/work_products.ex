defmodule Cympho.WorkProducts do
  import Ecto.Query, warn: false
  alias Cympho.Repo
  alias Cympho.WorkProducts.IssueWorkProduct
  alias Cympho.Issues.Issue
  alias Cympho.Activities

  def list_work_products(issue_id) do
    IssueWorkProduct
    |> where(issue_id: ^issue_id)
    |> order_by(desc: :inserted_at, desc: :id)
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

        broadcast_work_product({:work_product_created, work_product}, work_product.issue_id)

        _ = Cympho.ReviewNudges.reconcile_issue(work_product.issue_id)

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

        broadcast_work_product({:work_product_updated, updated}, updated.issue_id)

        {:ok, updated}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def delete_work_product(%IssueWorkProduct{} = work_product) do
    case Repo.delete(work_product) do
      {:ok, _} ->
        broadcast_work_product(
          {:work_product_deleted, work_product.issue_id},
          work_product.issue_id
        )

        :ok

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  # Work-product events are issue-scoped. We broadcast on the issue's
  # company-scoped topic (consumed by IssueLive.Show) rather than the bare
  # "issues" topic, which would leak across tenants. IssueWorkProduct has no
  # company_id column, so we resolve it from the parent issue.
  defp broadcast_work_product(message, issue_id) do
    case issue_company_id(issue_id) do
      nil -> {:error, :no_company}
      company_id -> Cympho.PubSubGuard.broadcast("company:#{company_id}:issues", message)
    end
  end

  defp issue_company_id(issue_id) when is_binary(issue_id) do
    Repo.one(from i in Issue, where: i.id == ^issue_id, select: i.company_id)
  end

  defp issue_company_id(_), do: nil
end
