defmodule Cympho.BoardApprovals.BoardApprovalEffect do
  @moduledoc false

  use Ecto.Schema

  alias Cympho.BoardApprovals.BoardApproval

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "board_approval_effects" do
    field :effect_key, :string
    field :category, :string

    belongs_to :board_approval, BoardApproval

    timestamps(type: :utc_datetime)
  end
end
