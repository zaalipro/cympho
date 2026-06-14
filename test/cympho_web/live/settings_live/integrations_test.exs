defmodule CymphoWeb.SettingsLive.IntegrationsTest do
  use CymphoWeb.LiveCase, async: true

  import Phoenix.LiveViewTest

  alias Cympho.Agrenting
  alias Cympho.Agents
  alias Cympho.Authentication
  alias Cympho.Secrets

  describe "Agrenting integration" do
    test "renders disconnected setup state", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/settings/integrations")

      assert html =~ "Integrations"
      assert html =~ "External AI control"
      assert html =~ "GET /api/mcp/tools"
      assert html =~ "POST /api/mcp/call"
      assert html =~ "Next operator move"
      assert html =~ "MCP setup checklist"
      assert html =~ "Agent identity"
      assert html =~ "Scoped API key"
      assert html =~ "CEO routing"
      assert html =~ "Tool catalog"
      assert html =~ "The shortest path from external AI client to CEO-owned work."
      assert html =~ "CEO intake recipe"
      assert html =~ "Copy recipe"
      assert html =~ ~s(data-testid="mcp-tool-catalog")
      assert html =~ "Expand when you need the full company-scoped tool catalog."
      assert html =~ ~s(&quot;assigned_role&quot;: &quot;ceo&quot;)
      assert html =~ "No agents"
      assert html =~ "Agrenting"
      assert html =~ "Not connected"
      assert html =~ "Save connection"
    end

    test "creates a scoped MCP API key for an agent", %{conn: conn, current_company: company} do
      {:ok, agent} =
        Agents.create_agent(%{
          company_id: company.id,
          name: "MCP Bridge",
          role: :ceo,
          status: :idle
        })

      {:ok, view, html} = live(conn, "/settings/integrations")

      assert html =~ "External AI control"
      assert html =~ "Key required"
      assert html =~ "MCP Bridge"
      assert html =~ "Create a scoped API key"
      assert html =~ "1 company agent identity can own external calls."
      assert html =~ "External requests can land directly in CEO review."

      html =
        view
        |> form("form[phx-submit='create_mcp_key']",
          mcp_key: %{
            agent_id: agent.id,
            name: "Owner MCP client"
          }
        )
        |> render_submit()

      assert html =~ "Copy this key now"
      assert html =~ "MCP Bridge"
      assert html =~ "X-API-Key"
      assert html =~ "Use create_issue with assigned_role"
      assert html =~ "1 scoped key can authenticate MCP clients."

      [api_key] = Authentication.list_agent_api_keys(agent.id)
      assert api_key.name == "Owner MCP client"
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
