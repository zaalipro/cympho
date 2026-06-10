defmodule CymphoWeb.SettingsHubTest do
  @moduledoc """
  End-to-end checks that the consolidated Settings hub mounts every relocated
  tab inside the shared shell, and that pre-hub URLs still redirect in.
  """
  use CymphoWeb.LiveCase, async: true
  import Ecto.Query

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
      assert html =~ "OpenAI Chat Qwen DashScope"
      assert html =~ "qwen3.7-plus"

      assert html =~
               "https://dashscope.aliyuncs.com/compatible-mode/v1"

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

    test "execution policies", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/settings/policies")
      assert html =~ "No execution policies yet."
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
end
