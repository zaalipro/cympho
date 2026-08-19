defmodule CymphoWeb.LabelLiveTest do
  use CymphoWeb.LiveCase, async: true

  alias Cympho.Companies
  alias Cympho.Labels

  defp create_company do
    unique = System.unique_integer([:positive])

    {:ok, company} =
      Companies.create_company(%{
        name: "Foreign Labels #{unique}",
        slug: "foreign-labels-#{unique}"
      })

    company
  end

  describe "LabelLive.Index" do
    test "mounts and renders the labels page", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/labels")

      assert html =~ "Labels"
      assert html =~ "Color-code work so the board reads at a glance."
      assert html =~ "Create a label"
    end

    test "renders an existing company label in the stream", %{
      conn: conn,
      current_company: company
    } do
      unique = System.unique_integer([:positive])

      {:ok, _label} =
        Labels.create_label(%{
          name: "Smoke Label #{unique}",
          color: "#FF0000",
          company_id: company.id
        })

      {:ok, _view, html} = live(conn, "/labels")

      assert html =~ "Smoke Label #{unique}"
    end

    test "does not list another company's labels", %{conn: conn} do
      unique = System.unique_integer([:positive])
      foreign = create_company()

      {:ok, _label} =
        Labels.create_label(%{
          name: "Foreign Smoke #{unique}",
          color: "#00FF00",
          company_id: foreign.id
        })

      {:ok, _view, html} = live(conn, "/labels")

      refute html =~ "Foreign Smoke #{unique}"
    end

    test "create stamps current_company.id and ignores client company_id", %{
      conn: conn,
      current_company: company
    } do
      unique = System.unique_integer([:positive])
      foreign = create_company()
      name = "Stamped Label #{unique}"

      {:ok, view, _html} = live(conn, "/labels")

      html =
        view
        |> element("form")
        |> render_submit(%{
          "label" => %{
            "name" => name,
            "color" => "#112233",
            "company_id" => foreign.id
          }
        })

      assert html =~ "Label created"
      assert html =~ name

      [label] = Labels.list_labels_by_company(company.id)
      assert label.name == name
      assert label.company_id == company.id
      assert Labels.list_labels_by_company(foreign.id) == []
    end

    test "edit of a foreign label flashes Label not found", %{conn: conn} do
      unique = System.unique_integer([:positive])
      foreign = create_company()

      {:ok, label} =
        Labels.create_label(%{
          name: "Keep Away #{unique}",
          color: "#ABCDEF",
          company_id: foreign.id
        })

      {:ok, view, _html} = live(conn, "/labels")

      html = render_click(view, "edit_label", %{"id" => label.id})

      assert html =~ "Label not found"
      refute html =~ "Editing: Keep Away #{unique}"

      assert {:ok, still} = Labels.get_label(label.id)
      assert still.name == "Keep Away #{unique}"
      assert still.company_id == foreign.id
    end

    test "update ignores client company_id", %{conn: conn, current_company: company} do
      unique = System.unique_integer([:positive])
      foreign = create_company()

      {:ok, label} =
        Labels.create_label(%{
          name: "Bound Label #{unique}",
          color: "#123456",
          company_id: company.id
        })

      {:ok, view, _html} = live(conn, "/labels")
      _html = render_click(view, "edit_label", %{"id" => label.id})

      html =
        render_submit(view, "update_label", %{
          "label" => %{
            "name" => "Still Bound #{unique}",
            "color" => "#654321",
            "company_id" => foreign.id
          }
        })

      assert html =~ "Label updated"

      updated = Labels.get_label!(label.id)
      assert updated.name == "Still Bound #{unique}"
      assert updated.company_id == company.id
      assert Labels.list_labels_by_company(foreign.id) == []
    end

    @tag membership_role: "admin"
    test "delete of a foreign label flashes Label not found and leaves it", %{conn: conn} do
      unique = System.unique_integer([:positive])
      foreign = create_company()

      {:ok, label} =
        Labels.create_label(%{
          name: "Do Not Delete #{unique}",
          color: "#FEDCBA",
          company_id: foreign.id
        })

      {:ok, view, _html} = live(conn, "/labels")

      html = render_click(view, "delete_label", %{"id" => label.id})

      assert html =~ "Label not found"
      assert {:ok, still} = Labels.get_label(label.id)
      assert still.name == "Do Not Delete #{unique}"
      assert still.company_id == foreign.id
    end
  end
end
