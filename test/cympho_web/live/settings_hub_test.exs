defmodule CymphoWeb.SettingsHubTest do
  @moduledoc """
  End-to-end checks that the consolidated Settings hub mounts every relocated
  tab inside the shared shell, and that pre-hub URLs still redirect in.
  """
  use CymphoWeb.LiveCase, async: true
  import Ecto.Query

  alias Cympho.Companies
  alias Cympho.Repo
  alias Cympho.Secrets
  alias Cympho.Secrets.Secret

  describe "hub tabs mount inside the shared shell" do
    test "profile", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/settings/profile")
      assert html =~ "Profile"
      assert html =~ "Save changes"
      # grouped sub-nav from the shell
      assert html =~ "Account"
      assert html =~ "Workspace"
      assert html =~ "Governance"
    end

    test "adapters", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/settings/adapters")
      assert html =~ "Adapter Status Overview"
    end

    test "secrets (company derived from current_company, no path param)", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/settings/secrets")
      assert html =~ "Add Secret"
      assert html =~ "Runtime credential cockpit"
      assert html =~ "0 of 4 ready"
      assert html =~ "No runtime secrets stored yet"
      assert html =~ "Runtime preflight uses these encrypted secrets"
      assert html =~ "Add runtime secret"
    end

    test "secrets summarizes runtime credential coverage without leaking values", %{
      conn: conn,
      current_company: company
    } do
      {:ok, secret} =
        Secrets.create_secret(%{
          company_id: company.id,
          scope: "company",
          key: "DASHSCOPE_API_KEY",
          value: "stored-provider-secret",
          description: "DashScope runtime credential"
        })

      {:ok, _view, html} = live(conn, "/settings/secrets")

      assert html =~ "Runtime credential cockpit"
      assert html =~ "1 of 4 ready"
      assert html =~ "CEO Qwen runtime"
      assert html =~ "DASHSCOPE_API_KEY is stored as an encrypted active secret."
      assert html =~ "Claude Code runtime"
      assert html =~ "Add ANTHROPIC_API_KEY at company scope."
      assert html =~ "key=ANTHROPIC_API_KEY"
      assert html =~ "qwen3.6-flash for smoke"
      assert html =~ "qwen3.7-plus"
      assert html =~ ~s(data-testid="secret-row-#{secret.id}")
      assert html =~ ~s(data-testid="secret-manage-menu-#{secret.id}")
      assert html =~ ~s(aria-label="Manage DASHSCOPE_API_KEY")
      assert html =~ "Version history"
      assert html =~ "Edit details"
      assert html =~ "Rotate secret"
      assert html =~ "Delete secret"

      assert html =~
               "Delete DASHSCOPE_API_KEY? Agents using this company-scoped credential will fail runtime preflight until a replacement is stored."

      refute html =~ "stored-provider-secret"
    end

    test "secrets shows rotation posture and opens rotate form", %{
      conn: conn,
      current_company: company
    } do
      {:ok, secret} =
        Secrets.create_secret(%{
          company_id: company.id,
          scope: "company",
          key: "ROTATE_ME",
          value: "old-runtime-key",
          description: "Runtime credential"
        })

      inserted_at = DateTime.utc_now() |> DateTime.add(-200 * 86_400, :second)

      Repo.update_all(from(s in Secret, where: s.id == ^secret.id),
        set: [inserted_at: inserted_at]
      )

      {:ok, view, html} = live(conn, "/settings/secrets")

      assert html =~ "Rotation posture"
      assert html =~ "1 of 1 active secrets need rotation attention."
      assert html =~ "Overdue"
      refute html =~ "old-runtime-key"

      html =
        view
        |> element(~s(button[phx-click="rotate"][phx-value-id="#{secret.id}"]))
        |> render_click()

      assert html =~ "Rotate Secret"
      assert html =~ "ROTATE_ME"
      refute html =~ "old-runtime-key"
    end

    test "secrets opens a prefilled add form from runtime preflight links", %{
      conn: conn,
      current_company: company
    } do
      path =
        "/settings/secrets?" <>
          URI.encode_query([
            {"key", "ANTHROPIC_API_KEY"},
            {"scope", "company"},
            {"description", "Runtime credential for CEO"}
          ])

      {:ok, view, html} = live(conn, path)

      assert html =~ "secret-form"
      assert html =~ "ANTHROPIC_API_KEY"
      assert html =~ "Runtime credential for CEO"
      assert html =~ "Runtime credential setup"
      assert html =~ "runtime-secret-setup-guide"
      assert html =~ "Claude-compatible / Qwen gateway"
      assert html =~ "ANTHROPIC_API_KEY can supply Claude-compatible wrappers"
      assert html =~ "Credential key"
      assert html =~ "Accepted by"
      assert html =~ "qwen3.6-flash for cheap smoke"
      assert html =~ "Save effect"
      assert html =~ "Runtime preflight can use this credential"
      assert html =~ "Encrypted at rest; the value is never shown after save."
      assert html =~ "No provider call on save"
      assert html =~ "Store encrypted runtime secret"
      assert html =~ "OpenAI Chat Qwen DashScope"
      assert html =~ "OpenAI Chat Qwen DashScope Flash / Plus / Intl"
      assert html =~ "qwen3.7-plus"

      refute html =~ "test-runtime-key"

      view
      |> form("#secret-form", %{
        "secret" => %{
          "key" => "ANTHROPIC_API_KEY",
          "scope" => "company",
          "value" => "test-runtime-key",
          "description" => "Runtime credential for CEO"
        }
      })
      |> render_submit()

      assert {:ok, secret} =
               Secrets.get_secret_by_key(company.id, "ANTHROPIC_API_KEY", scope: "company")

      assert {:ok, "test-runtime-key"} = Secrets.get_secret_value(secret.id)
    end

    test "secrets shows DashScope-specific runtime guidance for Qwen prefill links", %{
      conn: conn
    } do
      path =
        "/settings/secrets?" <>
          URI.encode_query([
            {"key", "DASHSCOPE_API_KEY"},
            {"scope", "company"},
            {"description", "DashScope runtime credential"},
            {"return_to", "/operations#runtime-launch-checklist"}
          ])

      {:ok, _view, html} = live(conn, path)

      assert html =~ "DashScope Qwen runtime setup"
      assert html =~ "OpenAI Chat Qwen DashScope Flash / Plus / Intl"
      assert html =~ "This secret unlocks DashScope compatible-mode chat completions"
      assert html =~ "Credential key"
      assert html =~ "DASHSCOPE_API_KEY"
      assert html =~ "Cheap smoke model"
      assert html =~ "qwen3.6-flash"
      assert html =~ "Planning model"
      assert html =~ "qwen3.7-plus"
      assert html =~ "https://dashscope.aliyuncs.com/compatible-mode/v1"
      assert html =~ "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"
      assert html =~ "Runtime preflight marks DashScope Qwen profiles ready"
      assert html =~ "After saving, Cympho returns to the runtime page"
      assert html =~ "No provider call on save"
      refute html =~ "sk-"
    end

    test "secrets returns to the source page after saving runtime preflight secret", %{
      conn: conn,
      current_company: company
    } do
      return_to = "/issues/00000000-0000-0000-0000-000000000000"

      path =
        "/settings/secrets?" <>
          URI.encode_query([
            {"key", "ANTHROPIC_API_KEY"},
            {"scope", "company"},
            {"description", "Runtime credential for CEO"},
            {"return_to", return_to}
          ])

      {:ok, view, html} = live(conn, path)

      assert html =~ "secret-form"
      assert html =~ "OpenAI Chat Qwen DashScope"
      assert html =~ "OpenAI Chat Qwen DashScope Flash / Plus / Intl"
      assert html =~ "After saving, Cympho returns to the runtime page"

      assert {:error, {:live_redirect, %{to: ^return_to}}} =
               view
               |> form("#secret-form", %{
                 "secret" => %{
                   "key" => "ANTHROPIC_API_KEY",
                   "scope" => "company",
                   "value" => "test-runtime-key",
                   "description" => "Runtime credential for CEO"
                 }
               })
               |> render_submit()

      assert {:ok, secret} =
               Secrets.get_secret_by_key(company.id, "ANTHROPIC_API_KEY", scope: "company")

      assert {:ok, "test-runtime-key"} = Secrets.get_secret_value(secret.id)
    end

    test "secrets ignores unsafe return paths from prefill links", %{
      conn: conn,
      current_company: company
    } do
      path =
        "/settings/secrets?" <>
          URI.encode_query([
            {"key", "ANTHROPIC_API_KEY"},
            {"scope", "company"},
            {"return_to", "https://evil.example/issues"}
          ])

      {:ok, view, html} = live(conn, path)

      assert html =~ "secret-form"

      html =
        view
        |> form("#secret-form", %{
          "secret" => %{
            "key" => "ANTHROPIC_API_KEY",
            "scope" => "company",
            "value" => "test-runtime-key",
            "description" => "Runtime credential for CEO"
          }
        })
        |> render_submit()

      assert is_binary(html)

      assert {:ok, _secret} =
               Secrets.get_secret_by_key(company.id, "ANTHROPIC_API_KEY", scope: "company")
    end

    test "secrets row actions are scoped to the current company", %{
      conn: conn,
      current_company: company
    } do
      other_company = create_company("foreign-secret")

      {:ok, foreign_secret} =
        Secrets.create_secret(%{
          company_id: other_company.id,
          scope: "company",
          key: "FOREIGN_RUNTIME_KEY",
          value: "foreign-secret-value",
          description: "Should remain isolated"
        })

      {:ok, local_secret} =
        Secrets.create_secret(%{
          company_id: company.id,
          scope: "company",
          key: "LOCAL_RUNTIME_KEY",
          value: "local-secret-value",
          description: "Visible local secret"
        })

      {:ok, view, html} = live(conn, "/settings/secrets")

      assert html =~ "LOCAL_RUNTIME_KEY"
      refute html =~ "FOREIGN_RUNTIME_KEY"

      html = render_click(view, "show_edit_form", %{"id" => foreign_secret.id})
      assert html =~ ~s(data-testid="secret-action-error")
      assert html =~ "Secret not found"
      refute html =~ "FOREIGN_RUNTIME_KEY"

      html = render_click(view, "show_versions", %{"id" => foreign_secret.id})
      assert html =~ "Secret not found"
      refute html =~ ~s(id="versions-modal")

      html = render_click(view, "rotate", %{"id" => foreign_secret.id})
      assert html =~ "Secret not found"
      refute html =~ "FOREIGN_RUNTIME_KEY"

      html = render_click(view, "delete", %{"id" => foreign_secret.id})
      assert html =~ "Secret not found"

      assert {:ok, _foreign_secret} = Secrets.get_secret(foreign_secret.id)
      assert {:ok, _local_secret} = Secrets.get_secret(local_secret.id)
    end

    test "execution policies", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/settings/policies")
      assert html =~ "No governance policies configured yet."
    end

    test "audit log", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/settings/audit")
      assert html =~ "Audit Trail"
    end
  end

  describe "legacy URLs redirect into the hub" do
    test "bare /settings", %{conn: conn} do
      assert redirected_to(get(conn, "/settings")) == "/settings/profile"
    end

    test "/adapters", %{conn: conn} do
      assert redirected_to(get(conn, "/adapters")) == "/settings/adapters"
    end

    test "/audit-trail", %{conn: conn} do
      assert redirected_to(get(conn, "/audit-trail")) == "/settings/audit"
    end

    test "/execution-policies", %{conn: conn} do
      assert redirected_to(get(conn, "/execution-policies")) == "/settings/policies"
    end

    test "/companies/:id/secrets switches to that company before the hub", %{
      conn: conn,
      current_company: company
    } do
      # Honors the company in the path (membership-checked by the switcher) so an
      # old deep link doesn't silently show a different company's secrets.
      assert redirected_to(get(conn, "/companies/#{company.id}/secrets")) ==
               "/switch-company/#{company.id}?return_to=%2Fsettings%2Fsecrets"
    end
  end

  defp create_company(label) do
    unique = System.unique_integer([:positive])

    {:ok, company} =
      Companies.create_company(%{
        name: "Settings #{label} #{unique}",
        slug: "settings-#{label}-#{unique}"
      })

    company
  end
end
