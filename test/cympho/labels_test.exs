defmodule Cympho.LabelsTest do
  use Cympho.DataCase
  alias Cympho.Labels
  alias Cympho.Labels.Label

  describe "create_label/1" do
    test "creates a label with valid attrs" do
      assert {:ok, %Label{} = label} =
               Labels.create_label(%{name: "Bug", color: "#FF0000", description: "Bug reports"})

      assert label.name == "Bug"
    end

    test "defaults color" do
      assert {:ok, %Label{} = label} = Labels.create_label(%{name: "Feature"})
      assert label.color == "#6B7280"
    end

    test "returns error for invalid color" do
      assert {:error, cs} = Labels.create_label(%{name: "Bad", color: "red"})
      assert %{color: ["must be a valid hex color (e.g. #FF0000)"]} = errors_on(cs)
    end

    test "returns error for duplicate name" do
      Labels.create_label(%{name: "Bug"})
      assert {:error, cs} = Labels.create_label(%{name: "Bug"})
      assert %{name: ["has already been taken"]} = errors_on(cs)
    end

    test "returns error for blank name" do
      assert {:error, cs} = Labels.create_label(%{name: ""})
      assert %{name: ["can't be blank"]} = errors_on(cs)
    end

    test "returns error for name too long" do
      assert {:error, cs} = Labels.create_label(%{name: String.duplicate("a", 51)})
      assert %{name: ["should be at most 50 character(s)"]} = errors_on(cs)
    end
  end

  test "list_labels/0 returns all" do
    Labels.create_label(%{name: "A"})
    Labels.create_label(%{name: "B"})
    assert length(Labels.list_labels()) == 2
  end

  test "get_label!/1 returns label" do
    {:ok, label} = Labels.create_label(%{name: "Test"})
    assert Labels.get_label!(label.id).name == "Test"
  end

  test "get_label!/1 raises on missing" do
    assert_raise Ecto.NoResultsError, fn -> Labels.get_label!(Ecto.UUID.generate()) end
  end

  test "get_label/1 returns ok or error" do
    {:ok, label} = Labels.create_label(%{name: "Test"})
    assert {:ok, ^label} = Labels.get_label(label.id)
    assert {:error, :not_found} = Labels.get_label(Ecto.UUID.generate())
  end

  test "update_label/2 updates" do
    {:ok, label} = Labels.create_label(%{name: "Old"})
    assert {:ok, updated} = Labels.update_label(label, %{name: "New"})
    assert updated.name == "New"
  end

  test "delete_label/1 deletes" do
    {:ok, label} = Labels.create_label(%{name: "Gone"})
    assert {:ok, %Label{}} = Labels.delete_label(label)
    assert {:error, :not_found} = Labels.get_label(label.id)
  end

  test "change_label/2 returns changeset" do
    {:ok, label} = Labels.create_label(%{name: "Test"})
    assert %Ecto.Changeset{} = Labels.change_label(label)
  end
end
