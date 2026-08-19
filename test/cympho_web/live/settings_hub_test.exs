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
    setup %{conn: conn, current_company: company} = context do
      user_id = Plug.Conn.get_session(conn, :user_id)
      membership = Companies.get_membership(user_id, company.id)

      role =
        context[:membership_role] || if(context[:regular_member], do: "member", else: "admin")

      assert {:ok, _membership} =
               Companies.update_membership(membership, %{
                 role: role,
                 is_board_member: context[:board_member] == true
               })

      :ok
    end

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
      assert html =~ "0 of 5 ready"
      assert html =~ "LLMotions runtime"
      assert html =~ "No runtime secrets stored yet"
      assert html =~ "Runtime preflight uses these encrypted secrets"
      assert html =~ "Add runtime secret"
    end

    test "proxies", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/settings/proxies")
      assert html =~ "Proxy Profiles"
      assert html =~ "Proxies"
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
      assert html =~ "1 of 5 ready"
      assert html =~ "CEO Qwen runtime"
      assert html =~ "LLMotions runtime"
      assert html =~ "DASHSCOPE_API_KEY is stored as an encrypted active secret."
      assert html =~ "Claude Code runtime"
      # "at company scope" repeated on all five cards without changing the action.
      assert html =~ "Add ANTHROPIC_API_KEY."
      refute html =~ "at company scope"
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

    @tag regular_member: true
    test "regular members can view secret metadata but cannot invoke any mutation", %{
      conn: conn,
      current_company: company
    } do
      {:ok, secret} =
        Secrets.create_secret(%{
          company_id: company.id,
          scope: "company",
          key: "READ_ONLY_RUNTIME_KEY",
          value: "member-must-not-see-or-change",
          description: "Original read-only description"
        })

      path = "/settings/secrets?" <> URI.encode_query(%{"key" => "MEMBER_CREATED_KEY"})
      {:ok, view, html} = live(conn, path)

      assert html =~ "READ_ONLY_RUNTIME_KEY"
      assert html =~ "Original read-only description"
      assert html =~ ~s(data-testid="secrets-read-only")
      refute html =~ "member-must-not-see-or-change"
      refute has_element?(view, ~s(button[phx-click="show_create_form"]))
      refute has_element?(view, ~s(button[phx-click="show_edit_form"]))
      refute has_element?(view, ~s(button[phx-click="rotate"]))
      refute has_element?(view, ~s(button[phx-click="delete"]))
      refute has_element?(view, "#secret-form")

      html = render_click(view, "show_versions", %{"id" => secret.id})
      assert html =~ ~s(id="versions-modal")

      for {event, params} <- [
            {"show_create_form", %{}},
            {"show_edit_form", %{"id" => secret.id}},
            {"rotate", %{"id" => secret.id}},
            {"delete", %{"id" => secret.id}}
          ] do
        assert render_click(view, event, params) =~
                 "Only company owners, admins, and board members can change secrets."
      end

      assert render_submit(view, "save", %{
               "secret" => %{
                 "key" => "MEMBER_CREATED_KEY",
                 "scope" => "company",
                 "value" => "unauthorized-value",
                 "description" => "Unauthorized mutation"
               }
             }) =~ "Only company owners, admins, and board members can change secrets."

      assert {:ok, reloaded} = Secrets.get_secret(secret.id)
      assert reloaded.description == "Original read-only description"
      assert reloaded.version == 1
      assert {:ok, "member-must-not-see-or-change"} = Secrets.get_secret_value(reloaded.id)

      assert {:error, :not_found} =
               Secrets.get_secret_by_key(company.id, "MEMBER_CREATED_KEY", scope: "company")
    end

    @tag membership_role: "member", board_member: true
    test "board members can manage company secrets", %{conn: conn} do
      {:ok, view, html} = live(conn, "/settings/secrets")

      refute html =~ ~s(data-testid="secrets-read-only")
      assert has_element?(view, ~s(button[phx-click="show_create_form"]))
    end

    @tag membership_role: "viewer", board_member: true
    test "a board flag does not make a viewer writable", %{conn: conn} do
      {:ok, view, html} = live(conn, "/settings/secrets")

      assert html =~ ~s(data-testid="secrets-read-only")
      refute has_element?(view, ~s(button[phx-click="show_create_form"]))

      assert render_click(view, "show_create_form", %{}) =~
               "Only company owners, admins, and board members can change secrets."
    end

    test "an open secret form rechecks authorization before saving", %{
      conn: conn,
      current_company: company
    } do
      {:ok, secret} =
        Secrets.create_secret(%{
          company_id: company.id,
          scope: "company",
          key: "REVOKED_EDITOR_KEY",
          value: "original-value",
          description: "Original description"
        })

      {:ok, view, _html} = live(conn, "/settings/secrets")

      view
      |> element(~s(button[phx-click="show_edit_form"][phx-value-id="#{secret.id}"]))
      |> render_click()

      user_id = Plug.Conn.get_session(conn, :user_id)
      membership = Companies.get_membership(user_id, company.id)

      assert {:ok, _membership} =
               Companies.update_membership(membership, %{
                 role: "member",
                 is_board_member: false
               })

      html =
        view
        |> form("#secret-form", %{
          "secret" => %{
            "scope" => "company",
            "description" => "Unauthorized description"
          }
        })
        |> render_submit()

      assert html =~ "Only company owners, admins, and board members can change secrets."

      assert {:ok, reloaded} = Secrets.get_secret(secret.id)
      assert reloaded.description == "Original description"
      assert reloaded.version == 1
      assert {:ok, "original-value"} = Secrets.get_secret_value(reloaded.id)
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
      assert has_element?(view, "[data-testid='secret-scope-field'].ui-advanced-only")

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

    test "generic secret scope controls are Advanced-only", %{conn: conn} do
      path =
        "/settings/secrets?" <>
          URI.encode_query([
            {"key", "PROJECT_API_KEY"},
            {"scope", "project"},
            {"scope_id", "project-scope"}
          ])

      {:ok, view, _html} = live(conn, path)

      assert has_element?(
               view,
               "[data-testid='secret-scope-field'].ui-advanced-only select[name='secret[scope]']"
             )

      assert has_element?(
               view,
               "[data-testid='secret-scope-id-field'].ui-advanced-only input[name='secret[scope_id]']"
             )
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

    test "secrets ignores an unauthorized company_id query parameter", %{
      conn: conn,
      current_company: company
    } do
      other_company = create_company("foreign-query-secret")

      {:ok, foreign_secret} =
        Secrets.create_secret(%{
          company_id: other_company.id,
          scope: "company",
          key: "FOREIGN_QUERY_RUNTIME_KEY",
          value: "foreign-query-secret-value",
          description: "Foreign query-only description"
        })

      {:ok, local_secret} =
        Secrets.create_secret(%{
          company_id: company.id,
          scope: "company",
          key: "LOCAL_QUERY_RUNTIME_KEY",
          value: "local-query-secret-value",
          description: "Local query description"
        })

      {:ok, view, html} = live(conn, "/settings/secrets?company_id=#{other_company.id}")

      assert html =~ "LOCAL_QUERY_RUNTIME_KEY"
      assert html =~ "Local query description"
      assert html =~ ~s(data-testid="secret-row-#{local_secret.id}")
      refute html =~ "FOREIGN_QUERY_RUNTIME_KEY"
      refute html =~ "Foreign query-only description"
      refute html =~ "foreign-query-secret-value"

      html = render_click(view, "show_versions", %{"id" => foreign_secret.id})
      assert html =~ "Secret not found"
      refute html =~ ~s(id="versions-modal")
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
