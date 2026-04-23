defmodule Cympho.Approvals.ApprovalIssue do
  use Ecto.Schema

  @primary_key false
  schema "approval_issues" do
    field :approval_id, :binary_id
    field :issue_id, :binary_id
  end
end
