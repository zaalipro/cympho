defmodule CymphoWeb.WorkProductJSON do
  alias Cympho.WorkProducts.IssueWorkProduct

  def index(%{work_products: work_products}) do
    %{data: Enum.map(work_products, &data/1)}
  end

  def show(%{work_product: %IssueWorkProduct{} = work_product}) do
    %{data: data(work_product)}
  end

  defp data(%IssueWorkProduct{} = wp) do
    %{
      id: wp.id,
      issue_id: wp.issue_id,
      created_by_agent_id: wp.created_by_agent_id,
      attachment_id: wp.attachment_id,
      kind: wp.kind,
      title: wp.title,
      description: wp.description,
      payload: wp.payload,
      url: wp.url,
      metadata: wp.metadata,
      inserted_at: wp.inserted_at,
      updated_at: wp.updated_at
    }
  end
end
