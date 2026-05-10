defmodule CymphoWeb.SettingsLive.IntegrationsTest do
  use CymphoWeb.LiveCase, async: true

  import Phoenix.LiveViewTest

  alias Cympho.Agrenting
  alias Cympho.Secrets

  describe "Agrenting integration" do
    test "renders disconnected setup state", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/settings/integrations")

      assert html =~ "Integrations"
      assert html =~ "Agrenting"
      assert html =~ "Not connected"
      assert html =~ "Save connection"
    end

    test "saves company-scoped Agrenting secrets", %{conn: conn, current_company: company} do
      {:ok, view, _html} = live(conn, "/settings/integrations")

      view
      |> form("form[phx-submit='save_agrenting']",
        agrenting: %{
          api_key: "ap_test_key",
          base_url: "https://agrenting.example.test",
          repo_access_token: "repo-token"
        }
      )
      |> render_submit()

      assert render(view) =~ "Connected"

      assert {:ok, api_key_secret} =
               Secrets.get_secret_by_key(company.id, Agrenting.api_key_secret(), scope: "company")

      assert {:ok, "ap_test_key"} = Secrets.get_secret_value(api_key_secret.id)

      assert {:ok, url_secret} =
               Secrets.get_secret_by_key(company.id, Agrenting.url_secret(), scope: "company")

      assert {:ok, "https://agrenting.example.test"} = Secrets.get_secret_value(url_secret.id)

      assert {:ok, repo_token_secret} =
               Secrets.get_secret_by_key(
                 company.id,
                 Agrenting.repo_access_token_secret(),
                 scope: "company"
               )

      assert {:ok, "repo-token"} = Secrets.get_secret_value(repo_token_secret.id)
    end

    test "disconnect deactivates Agrenting secrets", %{conn: conn, current_company: company} do
      assert {:ok, _status} =
               Agrenting.save_company_config(company.id, %{
                 "api_key" => "ap_test_key",
                 "base_url" => "https://agrenting.example.test"
               })

      {:ok, view, _html} = live(conn, "/settings/integrations")

      view
      |> element("button[phx-click='disconnect_agrenting']")
      |> render_click()

      assert render(view) =~ "Not connected"

      assert {:error, :not_found} =
               Secrets.get_secret_by_key(company.id, Agrenting.api_key_secret(), scope: "company")
    end
  end
end
