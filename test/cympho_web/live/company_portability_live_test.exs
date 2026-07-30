defmodule CymphoWeb.CompanyPortabilityLiveTest do
  use CymphoWeb.LiveCase, async: true

  import Phoenix.LiveViewTest

  alias Cympho.Companies
  alias Cympho.Projects
  alias Cympho.Secrets

  test "export page surfaces the portability command and secret restore manifest" do
    conn = authenticated_conn(%{is_board_member: true})
    company = current_company()

    {:ok, project} =
      Projects.create_project(%{
        name: "Portable Runtime",
        prefix: "PRT",
        company_id: company.id
      })

    {:ok, _secret} =
      Secrets.create_secret(%{
        company_id: company.id,
        scope: "project",
        scope_id: project.id,
        key: "PROJECT_TOKEN",
        value: "hidden-portability-token",
        description: "Project runtime credential"
      })

    {:ok, view, html} = live(conn, "/companies/#{company.id}/export")

    assert has_element?(view, "[data-testid='company-export-command']")
    assert has_element?(view, "[data-testid='secret-restore-manifest']")
    assert html =~ "Generate a portable operating export"
    assert html =~ "Secret restore checklist"
    assert html =~ "PROJECT_TOKEN"
    refute html =~ "hidden-portability-token"

    view
    |> element("button", "Generate export")
    |> render_click()

    html = render(view)

    assert html =~ "Export inventory"
    assert html =~ "Download JSON"
    assert html =~ "PROJECT_TOKEN"
    refute html =~ "hidden-portability-token"
  end

  test "export rejects a company the current board member cannot access" do
    conn = authenticated_conn(%{is_board_member: true})

    {:ok, foreign_company} =
      Companies.create_company(%{
        name: "Foreign Export Company",
        slug: "foreign-export-#{System.unique_integer([:positive])}"
      })

    assert {:error, {:redirect, %{to: "/companies"}}} =
             live(conn, "/companies/#{foreign_company.id}/export")
  end

  test "import page previews export contents and shows post-import secret restore actions" do
    conn = authenticated_conn(%{is_board_member: true})
    company = current_company()

    {:ok, project} =
      Projects.create_project(%{
        name: "Importable Runtime",
        prefix: "IRT",
        company_id: company.id
      })

    {:ok, _secret} =
      Secrets.create_secret(%{
        company_id: company.id,
        scope: "project",
        scope_id: project.id,
        key: "PROJECT_TOKEN",
        value: "never-import-this-value",
        description: "Project runtime credential"
      })

    export_json =
      company.id
      |> Companies.export_company()
      |> Jason.encode!()

    {:ok, view, html} = live(conn, "/companies/import")

    assert has_element?(view, "[data-testid='company-import-command']")
    assert html =~ "Import a portable company export"

    upload =
      file_input(view, "#company-import-upload", :import_file, [
        %{
          name: "portable-company.json",
          content: export_json,
          type: "application/json",
          last_modified: 1_700_000_000
        }
      ])

    render_upload(upload, "portable-company.json")

    view
    |> form("#company-import-upload")
    |> render_submit()

    html = render(view)

    assert has_element?(view, "[data-testid='company-import-preview']")
    assert html =~ "Preview #{company.name} before import"
    assert html =~ "Secret restore manifest"
    assert html =~ "PROJECT_TOKEN"
    refute html =~ "never-import-this-value"

    view
    |> element("button", "Start Import")
    |> render_click()

    html = render(view)

    assert html =~ "Import complete"
    assert html =~ "Secret restore queue"
    assert html =~ "PROJECT_TOKEN"
    assert html =~ "Add value"
    refute html =~ "never-import-this-value"
  end
end
