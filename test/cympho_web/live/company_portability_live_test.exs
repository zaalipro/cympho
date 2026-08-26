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

  test "import page renders accessible resumable-transfer controls" do
    conn = authenticated_conn(%{is_board_member: true})

    {:ok, view, html} = live(conn, "/companies/import")

    assert has_element?(view, "[data-testid='company-import-command']")
    assert has_element?(view, "#company-import-transfer[phx-hook='CompanyImportTransfer']")
    assert has_element?(view, "#company-import-file[type='file'][accept*='.json']")
    assert has_element?(view, "input[data-transfer-strategy][value='suffix'][checked]")
    assert has_element?(view, "input[data-transfer-strategy][value='fail']")
    assert has_element?(view, "[data-transfer-progressbar][role='progressbar']")
    assert has_element?(view, "[data-transfer-status][role='status'][aria-live='polite']")
    assert has_element?(view, "button[data-transfer-cancel]", "Pause")
    assert html =~ "verified 4 MiB parts"
    assert html =~ "Re-selecting the same file"
    assert html =~ "Keep the same choice when resuming"
    refute html =~ "authorization"
    refute html =~ "Bearer"
  end

  test "import transfer events keep only an id and preview/result plans in LiveView" do
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

    package = Companies.export_company(company.id)
    assert {:ok, preview} = Companies.preview_import(package)
    transfer_id = Ecto.UUID.generate()
    {:ok, view, _html} = live(conn, "/companies/import")

    render_hook(view, "transfer_declared", %{
      "transfer_id" => transfer_id,
      "slug_strategy" => "suffix"
    })

    html =
      render_hook(view, "transfer_previewed", %{
        "transfer_id" => transfer_id,
        "slug_strategy" => "suffix",
        "preview" => stringify_keys(preview)
      })

    assert has_element?(view, "[data-testid='company-import-preview']")
    assert html =~ "Preview #{company.name} before import"
    assert html =~ "#{company.slug}-copy"
    assert html =~ "PROJECT_TOKEN"
    refute html =~ "never-import-this-value"

    view
    |> element("button", "Start Import")
    |> render_click()

    assert_push_event(view, "company-import:apply", %{
      transfer_id: ^transfer_id,
      slug_strategy: "suffix"
    })

    render_click(view, "start_import", %{})

    refute_push_event(view, "company-import:apply", %{
      transfer_id: ^transfer_id,
      slug_strategy: "suffix"
    })

    imported_company_id = Ecto.UUID.generate()

    html =
      render_hook(view, "transfer_applied", %{
        "transfer_id" => transfer_id,
        "result" => %{
          "data" => %{
            "id" => imported_company_id,
            "name" => company.name,
            "slug" => "#{company.slug}-copy"
          },
          "secrets_to_restore" => [
            %{
              "key" => "PROJECT_TOKEN",
              "scope" => "project",
              "restore_status" => "requires_value"
            }
          ]
        }
      })

    assert html =~ "Import complete"
    assert html =~ "Secret restore queue"
    assert html =~ "PROJECT_TOKEN"
    assert html =~ "Add value"
    refute html =~ "never-import-this-value"

    assert_switch_path(
      link_href(html, "a", "View imported company"),
      imported_company_id,
      "/companies/#{imported_company_id}"
    )

    secret_path =
      assert_switch_path(
        link_href(html, "a", "Add value"),
        imported_company_id
      )

    secret_uri = URI.parse(secret_path)
    assert secret_uri.path == "/settings/secrets"

    assert URI.decode_query(secret_uri.query) == %{
             "description" => "Restored from company import",
             "key" => "PROJECT_TOKEN",
             "return_to" => "/companies/#{imported_company_id}",
             "scope" => "project"
           }
  end

  test "import transfer rejects stale and malformed client events" do
    conn = authenticated_conn(%{is_board_member: true})
    {:ok, view, _html} = live(conn, "/companies/import")

    html = render_hook(view, "transfer_declared", %{"transfer_id" => "not-a-uuid"})
    assert html =~ "invalid transfer ID"
    refute has_element?(view, "[data-testid='company-import-preview']")

    transfer_id = Ecto.UUID.generate()
    other_id = Ecto.UUID.generate()

    render_hook(view, "transfer_declared", %{
      "transfer_id" => transfer_id,
      "slug_strategy" => "suffix"
    })

    _html =
      render_hook(view, "transfer_previewed", %{
        "transfer_id" => other_id,
        "slug_strategy" => "suffix",
        "preview" => %{"ready?" => true}
      })

    refute has_element?(view, "[data-testid='company-import-preview']")
  end

  test "resumed declaration keeps its immutable slug strategy selected" do
    conn = authenticated_conn(%{is_board_member: true})
    transfer_id = Ecto.UUID.generate()
    {:ok, view, _html} = live(conn, "/companies/import")

    render_hook(view, "transfer_declared", %{
      "transfer_id" => transfer_id,
      "slug_strategy" => "fail"
    })

    assert has_element?(view, "input[data-transfer-strategy][value='fail'][checked]")
    refute has_element?(view, "input[data-transfer-strategy][value='suffix'][checked]")
  end

  test "completed transfer resume keeps its secret checklist and switches company before links" do
    conn = authenticated_conn(%{is_board_member: true})
    transfer_id = Ecto.UUID.generate()
    imported_company_id = Ecto.UUID.generate()
    {:ok, view, _html} = live(conn, "/companies/import")

    html =
      render_hook(view, "transfer_completed", %{
        "transfer_id" => transfer_id,
        "imported_company_id" => imported_company_id,
        "restore_receipt_available" => true,
        "secrets_to_restore" => [
          %{
            "key" => "RESUMED_TOKEN",
            "scope" => "company",
            "description" => "Restore after resuming",
            "restore_status" => "requires_value"
          }
        ]
      })

    assert html =~ "Import already complete"
    assert html =~ "No data was imported a second time"

    assert html =~ "Secret restore queue"
    assert html =~ "RESUMED_TOKEN"
    assert html =~ "1 keys"

    assert_switch_path(
      link_href(html, "a", "View imported company"),
      imported_company_id,
      "/companies/#{imported_company_id}"
    )

    secret_path =
      assert_switch_path(
        link_href(html, "a", "Add value"),
        imported_company_id
      )

    secret_uri = URI.parse(secret_path)
    assert secret_uri.path == "/settings/secrets"

    assert URI.decode_query(secret_uri.query) == %{
             "description" => "Restore after resuming",
             "key" => "RESUMED_TOKEN",
             "return_to" => "/companies/#{imported_company_id}",
             "scope" => "company"
           }
  end

  test "completed transfer without a persisted receipt reports an unknown checklist" do
    conn = authenticated_conn(%{is_board_member: true})
    transfer_id = Ecto.UUID.generate()
    imported_company_id = Ecto.UUID.generate()
    {:ok, view, _html} = live(conn, "/companies/import")

    _html =
      render_hook(view, "transfer_completed", %{
        "transfer_id" => transfer_id,
        "imported_company_id" => imported_company_id
      })

    assert has_element?(
             view,
             "[data-testid='import-secret-restore-unavailable']",
             "Secret checklist unavailable"
           )

    refute has_element?(view, "[data-testid='import-secret-restore']")
  end

  defp assert_switch_path(path, company_id, expected_return_to \\ nil) do
    uri = URI.parse(path)
    assert uri.path == "/switch-company/#{company_id}"

    return_to = uri.query |> URI.decode_query() |> Map.fetch!("return_to")

    if expected_return_to do
      assert return_to == expected_return_to
    end

    return_to
  end

  defp link_href(html, selector, text) do
    links =
      html
      |> Floki.parse_fragment!()
      |> Floki.find(selector)
      |> Enum.filter(fn link ->
        link
        |> Floki.text()
        |> String.contains?(text)
      end)

    assert [link] = links
    assert [href] = Floki.attribute(link, "href")
    href
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), stringify_keys(nested)} end)
  end

  defp stringify_keys(value), do: value
end
