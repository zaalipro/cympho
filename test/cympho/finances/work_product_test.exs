defmodule Cympho.Finances.WorkProductTest do
  use Cympho.DataCase, async: true

  alias Cympho.Finances.WorkProduct

  describe "changeset/2" do
    test "valid changeset with required fields" do
      issue_id = Ecto.UUID.generate()

      changeset =
        WorkProduct.changeset(%WorkProduct{}, %{
          issue_id: issue_id,
          name: "implementation.ex",
          content_type: "text/elixir"
        })

      assert changeset.valid?
    end

    test "requires issue_id, name, and content_type" do
      changeset = WorkProduct.changeset(%WorkProduct{}, %{})

      refute changeset.valid?

      assert %{
               issue_id: ["can't be blank"],
               name: ["can't be blank"],
               content_type: ["can't be blank"]
             } = errors_on(changeset)
    end

    test "name must not exceed 255 characters" do
      issue_id = Ecto.UUID.generate()

      changeset =
        WorkProduct.changeset(%WorkProduct{}, %{
          issue_id: issue_id,
          name: String.duplicate("a", 256),
          content_type: "text/plain"
        })

      refute changeset.valid?
    end
  end
end
