defmodule Cympho.LabelsTest do
  use Cympho.DataCase
  alias Cympho.Companies
  alias Cympho.Labels
  alias Cympho.Labels.Label

  defp create_company do
    unique = System.unique_integer([:positive])

    {:ok, company} =
      Companies.create_company(%{
        name: "Labels Co #{unique}",
        slug: "labels-co-#{unique}"
      })

    company
  end

  describe "create_label/1" do
    test "creates a label with valid attrs" do
      company = create_company()

      assert {:ok, %Label{} = label} =
               Labels.create_label(%{
                 name: "Bug",
                 color: "#FF0000",
                 description: "Bug reports",
                 company_id: company.id
               })

      assert label.name == "Bug"
      assert label.company_id == company.id
    end

    test "defaults color" do
      company = create_company()

      assert {:ok, %Label{} = label} =
               Labels.create_label(%{name: "Feature", company_id: company.id})

      assert label.color == "#6B7280"
    end

    test "returns error for invalid color" do
      company = create_company()

      assert {:error, cs} =
               Labels.create_label(%{name: "Bad", color: "red", company_id: company.id})

      assert %{color: ["must be a valid hex color (e.g. #FF0000)"]} = errors_on(cs)
    end

    test "returns error for duplicate name" do
      company = create_company()
      Labels.create_label(%{name: "Bug", company_id: company.id})
      assert {:error, cs} = Labels.create_label(%{name: "Bug", company_id: company.id})
      assert %{name: ["has already been taken"]} = errors_on(cs)
    end

    test "returns error for blank name" do
      company = create_company()
      assert {:error, cs} = Labels.create_label(%{name: "", company_id: company.id})
      assert %{name: ["can't be blank"]} = errors_on(cs)
    end

    test "returns error for name too long" do
      company = create_company()

      assert {:error, cs} =
               Labels.create_label(%{name: String.duplicate("a", 51), company_id: company.id})

      assert %{name: ["should be at most 50 character(s)"]} = errors_on(cs)
    end

    test "returns error without company_id" do
      assert {:error, cs} = Labels.create_label(%{name: "Orphan"})
      assert %{company_id: ["can't be blank"]} = errors_on(cs)
    end
  end

  test "list_labels/0 remains unscoped" do
    a = create_company()
    b = create_company()
    Labels.create_label(%{name: "A", company_id: a.id})
    Labels.create_label(%{name: "B", company_id: b.id})

    names = Enum.map(Labels.list_labels(), & &1.name)
    assert "A" in names
    assert "B" in names
    assert length(Labels.list_labels()) == 2
  end

  describe "list_company_labels_page/2" do
    test "pages only the given company's labels" do
      a = create_company()
      b = create_company()
      {:ok, ours} = Labels.create_label(%{name: "Ours", company_id: a.id})
      {:ok, _theirs} = Labels.create_label(%{name: "Theirs", company_id: b.id})

      page = Labels.list_company_labels_page(a.id)
      assert Enum.map(page.entries, & &1.id) == [ours.id]
      refute page.has_more?
    end

    test "honors limit and after cursor" do
      company = create_company()
      {:ok, alpha} = Labels.create_label(%{name: "Alpha", company_id: company.id})
      {:ok, beta} = Labels.create_label(%{name: "Beta", company_id: company.id})

      page1 = Labels.list_company_labels_page(company.id, limit: 1)
      assert Enum.map(page1.entries, & &1.id) == [alpha.id]
      assert page1.has_more?

      page2 = Labels.list_company_labels_page(company.id, limit: 1, after: page1.next_cursor)
      assert Enum.map(page2.entries, & &1.id) == [beta.id]
    end
  end

  test "list_labels_by_company/1 returns only that company's labels" do
    a = create_company()
    b = create_company()
    {:ok, ours} = Labels.create_label(%{name: "Company A", company_id: a.id})
    {:ok, _theirs} = Labels.create_label(%{name: "Company B", company_id: b.id})

    assert Enum.map(Labels.list_labels_by_company(a.id), & &1.id) == [ours.id]
  end

  test "get_label!/1 returns label" do
    company = create_company()
    {:ok, label} = Labels.create_label(%{name: "Test", company_id: company.id})
    assert Labels.get_label!(label.id).name == "Test"
  end

  test "get_label!/1 raises on missing" do
    assert_raise Ecto.NoResultsError, fn -> Labels.get_label!(Ecto.UUID.generate()) end
  end

  test "get_label/1 returns ok or error" do
    company = create_company()
    {:ok, label} = Labels.create_label(%{name: "Test", company_id: company.id})
    assert {:ok, fetched} = Labels.get_label(label.id)
    assert fetched.id == label.id
    assert {:error, :not_found} = Labels.get_label(Ecto.UUID.generate())
  end

  test "get_company_label/2 returns the label only inside its company" do
    a = create_company()
    b = create_company()
    {:ok, label} = Labels.create_label(%{name: "Scoped", company_id: a.id})

    assert {:ok, fetched} = Labels.get_company_label(a.id, label.id)
    assert fetched.id == label.id
    assert {:error, :not_found} = Labels.get_company_label(b.id, label.id)
  end

  test "update_label/2 updates" do
    company = create_company()
    {:ok, label} = Labels.create_label(%{name: "Old", company_id: company.id})
    assert {:ok, updated} = Labels.update_label(label, %{name: "New"})
    assert updated.name == "New"
  end

  test "delete_label/1 deletes" do
    company = create_company()
    {:ok, label} = Labels.create_label(%{name: "Gone", company_id: company.id})
    assert {:ok, %Label{}} = Labels.delete_label(label)
    assert {:error, :not_found} = Labels.get_label(label.id)
  end

  test "change_label/2 returns changeset" do
    company = create_company()
    {:ok, label} = Labels.create_label(%{name: "Test", company_id: company.id})
    assert %Ecto.Changeset{} = Labels.change_label(label)
  end

  test "changeset requires company_id" do
    cs = Label.changeset(%Label{}, %{name: "Needs Company"})
    refute cs.valid?
    assert %{company_id: ["can't be blank"]} = errors_on(cs)
  end
end
