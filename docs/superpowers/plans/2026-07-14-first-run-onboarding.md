# First-Run Setup & Company Onboarding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A fresh deploy walks the operator from zero users → owner account → company + CEO/CTO/engineers via a wizard, and company-less users can never create orphan data again.

**Architecture:** Three layers — (1) engine: `Companies.create_autonomous_company/1` learns `owner_user_id` (creates the missing `CompanyMembership`), `engineer_names`, and `agent_runtime`; (2) gates: a `/setup` first-run controller, an `on_mount(:require_company)` + `require_company` plug that funnel company-less users into `/onboarding`, and an invite-only lock on `/api/register`; (3) UI: the `/onboarding` LiveView becomes a 6-step wizard (welcome → blueprint → company → team → launch → ready). Data hardening (projects.company_id NOT NULL with orphan adoption) ships as a **separate second deploy**.

**Tech Stack:** Phoenix 1.8 / LiveView 1.1, Ecto, existing test suites (`ConnCase`, `LiveCase`, `DataCase`).

**Spec:** `docs/superpowers/specs/2026-07-14-first-run-onboarding-design.md`

**Key facts discovered during research (trust these, don't re-derive):**
- `create_autonomous_company` (lib/cympho/companies.ex:1907) runs one `Repo.transaction` using `Repo.insert!` throughout; it creates CEO, CTO, N engineers, Product Lead, Design Lead + blueprint `extra_agents`, always. `CompanyMembership` is aliased at the top of the module.
- `create_template_agent!` (companies.ex:2327) currently **overwrites** `runtime_config` with `%{"autonomous" => true}` via `Map.merge(attrs, %{...})` — attrs-supplied runtime_config would be discarded; Task 1 fixes this.
- Adapter command resolution: `claude_code_adapter.get_command/1` reads `config["command"]`; `Orchestrator.agent_config/1` merges `agent.config` + `agent.runtime_config`, and `Orchestrator.profile_env/1` reads `runtime_config["env"]` for env injection → model goes to `runtime_config["env"]["ANTHROPIC_MODEL"]`.
- `UserAuth.on_mount(:default)` assigns `:current_user`, `:user_companies`, `:current_company` (nil-safe). `require_authenticated_user` plug assigns `:current_company` on conn (possibly nil).
- `SessionController` already aliases `Repo`, `User`, `CompanyMembership`; `sign_in/2` is public and sets `:user_id` + `:company_id` session keys.
- The engine's `unique_project_prefix/1` auto-uniquifies prefixes, so no wizard-side uniqueness check is needed.
- `LiveCase.authenticated_conn` and `ConnCase.register_and_log_in_user` both create user+company+membership → existing tests pass the new gates.
- `test/cympho_web/controllers/session_controller_test.exs` has two `get /login` tests with **no user in the DB** — they will hit the new zero-user redirect and must seed a user first (a `registered_user()` helper already exists in that file).
- The heartbeat/watchdog/scheduler processes don't touch projects/onboarding — no OTP changes needed.

---

### Task 1: Engine — owner membership, engineer names, agent runtime

**Files:**
- Modify: `lib/cympho/companies.ex`
- Test: `test/cympho/companies_onboarding_test.exs` (create)

- [ ] **Step 1: Write the failing tests**

```elixir
defmodule Cympho.CompaniesOnboardingTest do
  use Cympho.DataCase, async: true

  alias Cympho.Companies

  defp create_user! do
    {:ok, user} =
      Cympho.Users.create_user(%{
        email: "owner-#{System.unique_integer([:positive])}@example.com",
        name: "Owner",
        password: "password1234"
      })

    user
  end

  describe "create_autonomous_company/1 owner linkage" do
    test "creates an owner board membership and sets the user's default company" do
      user = create_user!()

      {:ok, %{company: company}} =
        Companies.create_autonomous_company(%{name: "Owned Co", owner_user_id: user.id})

      membership = Companies.get_membership(user.id, company.id)
      assert membership.role == "owner"
      assert membership.is_board_member

      {:ok, reloaded} = Cympho.Users.get_user(user.id)
      assert reloaded.company_id == company.id
    end

    test "without owner_user_id no membership is created (backward compatible)" do
      {:ok, %{company: company}} = Companies.create_autonomous_company(%{name: "Legacy Co"})

      assert Companies.list_memberships(company.id) == []
    end
  end

  describe "create_autonomous_company/1 engineer names" do
    test "names engineer agents in order, padding with defaults" do
      {:ok, %{agents: agents}} =
        Companies.create_autonomous_company(%{
          name: "Named Co",
          engineer_count: 3,
          engineer_names: ["Ada", "Grace", ""]
        })

      engineer_names =
        agents |> Enum.filter(&(&1.role == :engineer)) |> Enum.map(& &1.name)

      assert engineer_names == ["Ada", "Grace", "Engineer 3"]
    end
  end

  describe "create_autonomous_company/1 agent runtime" do
    test "command and model land in every agent's runtime_config" do
      {:ok, %{agents: agents}} =
        Companies.create_autonomous_company(%{
          name: "Runtime Co",
          engineer_count: 1,
          agent_runtime: %{"command" => "cz", "model" => "claude-sonnet-5"}
        })

      assert agents != []

      for agent <- agents do
        assert agent.runtime_config["command"] == "cz"
        assert agent.runtime_config["env"]["ANTHROPIC_MODEL"] == "claude-sonnet-5"
        assert agent.runtime_config["autonomous"] == true
      end
    end

    test "blank runtime values are dropped and autonomous default is preserved" do
      {:ok, %{agents: agents}} =
        Companies.create_autonomous_company(%{
          name: "Default Runtime Co",
          engineer_count: 1,
          agent_runtime: %{"command" => "  ", "model" => ""}
        })

      for agent <- agents do
        refute Map.has_key?(agent.runtime_config, "command")
        refute Map.has_key?(agent.runtime_config, "env")
        assert agent.runtime_config["autonomous"] == true
      end
    end
  end
end
```

(Verified: `Companies.list_memberships/1` (companies.ex:2461) lists a company's memberships preloaded with users; `Companies.get_membership/2` (companies.ex:2475) fetches by user+company.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/cympho/companies_onboarding_test.exs`
Expected: FAIL — membership is `nil`, engineer names are `["Engineer 1", ...]`, runtime_config lacks "command".

- [ ] **Step 3: Implement in `lib/cympho/companies.ex`**

3a. In `create_autonomous_company/1`, after the existing `adapter = normalize_adapter(...)` line, add:

```elixir
    owner_user_id = attrs[:owner_user_id] || attrs["owner_user_id"]
    engineer_names = normalize_engineer_names(attrs[:engineer_names] || attrs["engineer_names"])
    agent_runtime = normalize_agent_runtime(attrs[:agent_runtime] || attrs["agent_runtime"])
```

3b. Inside the transaction, immediately after `company = ... |> Repo.insert!()`, add:

```elixir
      if owner_user_id do
        %CompanyMembership{}
        |> CompanyMembership.changeset(%{
          user_id: owner_user_id,
          company_id: company.id,
          role: "owner",
          is_board_member: true
        })
        |> Repo.insert!()

        case Cympho.Users.get_user(owner_user_id) do
          {:ok, user} ->
            user |> Ecto.Changeset.change(company_id: company.id) |> Repo.update!()

          {:error, :not_found} ->
            Repo.rollback(:owner_not_found)
        end
      end
```

3c. Add `runtime_config: agent_runtime` to **every** `create_template_agent!` call in the transaction (ceo, cto, the engineer loop, product_lead, design_lead) and to the `base_attrs` map passed to `create_blueprint_extra_agents!` (and from there into its `create_template_agent!` call: add `runtime_config: base_attrs.runtime_config`).

3d. In the engineer loop, replace `name: "Engineer #{index}"` with:

```elixir
              name: engineer_name(engineer_names, index),
```

3e. Rework `create_template_agent!/1` so attrs-supplied runtime config merges over the default instead of being discarded:

```elixir
  defp create_template_agent!(attrs) do
    role = attrs[:role] || attrs["role"]
    runtime_config = Map.merge(%{"autonomous" => true}, attrs[:runtime_config] || %{})

    attrs =
      attrs
      |> Map.delete(:runtime_config)
      |> Map.update(
        :instructions,
        RolePlaybook.default_overrides_template(role),
        &RolePlaybook.starter_overrides(role, &1)
      )

    %Agent{}
    |> Agent.changeset(
      Map.merge(attrs, %{
        status: :idle,
        context_mode: "company",
        runtime_config: runtime_config
      })
    )
    |> Repo.insert!()
  end
```

3f. Add the private normalizers next to `normalize_engineer_count/1`:

```elixir
  defp normalize_engineer_names(names) when is_list(names) do
    Enum.map(names, fn
      name when is_binary(name) -> String.trim(name)
      _ -> ""
    end)
  end

  defp normalize_engineer_names(_), do: []

  defp engineer_name(names, index) do
    case Enum.at(names, index - 1) do
      name when is_binary(name) and name != "" -> name
      _ -> "Engineer #{index}"
    end
  end

  # Builds the extra runtime_config merged into every launched agent.
  # command -> top-level "command" (read by adapters via the orchestrator's
  # config merge); model -> "env"."ANTHROPIC_MODEL" (injected by profile_env).
  defp normalize_agent_runtime(%{} = runtime) do
    command = trim_or_nil(runtime["command"] || runtime[:command])
    model = trim_or_nil(runtime["model"] || runtime[:model])

    %{}
    |> then(fn config -> if command, do: Map.put(config, "command", command), else: config end)
    |> then(fn config ->
      if model, do: Map.put(config, "env", %{"ANTHROPIC_MODEL" => model}), else: config
    end)
  end

  defp normalize_agent_runtime(_), do: %{}

  defp trim_or_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trim_or_nil(_), do: nil
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/cympho/companies_onboarding_test.exs`
Expected: PASS (all 5)

- [ ] **Step 5: Run the existing companies/onboarding tests for regressions**

Run: `mix test test/cympho/ test/cympho_web/live/onboarding_live_test.exs`
Expected: PASS (create_template_agent! change is backward compatible)

- [ ] **Step 6: Commit**

```bash
git add lib/cympho/companies.ex test/cympho/companies_onboarding_test.exs
git commit -m "Add owner membership, engineer names, agent runtime to company launch"
```

---

### Task 2: Require company_id on projects (changeset layer)

**Files:**
- Modify: `lib/cympho/projects/project.ex`
- Test: `test/cympho/projects_company_requirement_test.exs` (create)

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Cympho.ProjectsCompanyRequirementTest do
  use Cympho.DataCase, async: true

  alias Cympho.Projects

  test "create_project without company_id is invalid" do
    assert {:error, changeset} =
             Projects.create_project(%{"name" => "Orphan", "prefix" => "ORPH"})

    assert %{company_id: ["can't be blank"]} = errors_on(changeset)
  end

  test "create_project with company_id succeeds" do
    {:ok, company} =
      Cympho.Companies.create_company(%{name: "Proj Co", slug: "proj-co-#{System.unique_integer([:positive])}"})

    assert {:ok, project} =
             Projects.create_project(%{
               "name" => "Real",
               "prefix" => "REAL",
               "company_id" => company.id
             })

    assert project.company_id == company.id
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/cympho/projects_company_requirement_test.exs`
Expected: first test FAILS (changeset currently valid without company_id)

- [ ] **Step 3: Implement**

In `lib/cympho/projects/project.ex`, change `validate_required([:name, :prefix])` to:

```elixir
    |> validate_required([:name, :prefix, :company_id])
    |> foreign_key_constraint(:company_id)
```

(Keep the rest of the pipeline — length/format/unique_constraint on prefix — untouched.)

- [ ] **Step 4: Run tests**

Run: `mix test test/cympho/projects_company_requirement_test.exs`
Expected: PASS

- [ ] **Step 5: Full-suite spot check for fixtures that created projects without a company**

Run: `mix test`
Expected: PASS. If any test fails on the new validation, fix that fixture by passing the test's company id (all known call sites — engine, ProjectLive.New, company import, workspace_health_test — already pass company_id).

- [ ] **Step 6: Commit**

```bash
git add lib/cympho/projects/project.ex test/cympho/projects_company_requirement_test.exs
git commit -m "Require company_id on project changesets"
```

---

### Task 3: Company gates (LiveView on_mount + conn plug + router)

**Files:**
- Modify: `lib/cympho_web/user_auth.ex`
- Modify: `lib/cympho_web/router.ex`
- Test: `test/cympho_web/require_company_gate_test.exs` (create)

- [ ] **Step 1: Write the failing tests**

```elixir
defmodule CymphoWeb.RequireCompanyGateTest do
  use CymphoWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  defp companyless_conn do
    {:ok, user} =
      Cympho.Users.create_user(%{
        email: "solo-#{System.unique_integer([:positive])}@example.com",
        name: "Solo",
        password: "password1234"
      })

    build_conn()
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:user_id, user.id)
  end

  test "live routes redirect company-less users to onboarding" do
    assert {:error, {:redirect, %{to: "/onboarding"}}} = live(companyless_conn(), "/issues")
  end

  test "controller routes redirect company-less users to onboarding" do
    conn = get(companyless_conn(), "/switch-company/#{Ecto.UUID.generate()}")
    assert redirected_to(conn) == "/onboarding"
  end

  test "onboarding stays reachable for company-less users" do
    assert {:ok, _view, html} = live(companyless_conn(), "/onboarding")
    assert html =~ "Step 1"
  end

  test "users with a company pass through" do
    {conn, _user, _company} = CymphoWeb.ConnCase.register_and_log_in_user(build_conn())
    assert {:ok, _view, _html} = live(conn, "/issues")
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/cympho_web/require_company_gate_test.exs`
Expected: tests 1–2 FAIL (no redirect happens yet)

- [ ] **Step 3: Add the gate functions to `lib/cympho_web/user_auth.ex`**

Directly below the existing `on_mount(:default, ...)` clause:

```elixir
  # Blocks company-less users from the app proper; they are funneled into
  # /onboarding (its live_session mounts only :default) until they own a
  # company membership. Prevents orphan rows like projects with NULL company.
  def on_mount(:require_company, _params, _session, socket) do
    case socket.assigns[:current_company] do
      %{id: _} -> {:cont, socket}
      _ -> {:halt, Phoenix.LiveView.redirect(socket, to: "/onboarding")}
    end
  end
```

Below `require_authenticated_user/2`:

```elixir
  # Conn-level twin of on_mount(:require_company) for non-LiveView routes.
  def require_company(conn, _opts) do
    case conn.assigns[:current_company] do
      %{id: _} ->
        conn

      _ ->
        conn
        |> Phoenix.Controller.redirect(to: "/onboarding")
        |> Plug.Conn.halt()
    end
  end
```

- [ ] **Step 4: Rewire `lib/cympho_web/router.ex`**

4a. Add a pipeline after `:authenticated_browser`:

```elixir
  pipeline :company_scoped do
    plug :require_company
  end
```

4b. Next to the existing `defp require_authenticated_user` delegation at the bottom:

```elixir
  defp require_company(conn, opts) do
    CymphoWeb.UserAuth.require_company(conn, opts)
  end
```

4c. Add a dedicated onboarding scope **above** the main authenticated scope (no `:company_scoped`):

```elixir
  scope "/", CymphoWeb do
    pipe_through [:browser, :authenticated_browser]

    live_session :onboarding, on_mount: [{CymphoWeb.UserAuth, :default}] do
      live "/onboarding", OnboardingLive.Index
    end
  end
```

4d. In the main scope: change `pipe_through [:browser, :authenticated_browser]` to `pipe_through [:browser, :authenticated_browser, :company_scoped]`, **delete** the `live "/onboarding", OnboardingLive.Index` line from the `:default` live_session, and append the gate to all three live_sessions:

```elixir
    live_session :default,
      on_mount: [{CymphoWeb.UserAuth, :default}, {CymphoWeb.UserAuth, :require_company}] do
```

```elixir
    live_session :board_governed,
      on_mount: [
        {CymphoWeb.UserAuth, :default},
        {CymphoWeb.UserAuth, :require_company},
        {CymphoWeb.Live.BoardAuth, :default}
      ] do
```

```elixir
    live_session :authenticated_company_show,
      on_mount: [{CymphoWeb.UserAuth, :default}, {CymphoWeb.UserAuth, :require_company}] do
```

- [ ] **Step 5: Run gate tests + full suite**

Run: `mix test test/cympho_web/require_company_gate_test.exs && mix test`
Expected: PASS everywhere (LiveCase/ConnCase users have memberships; the dev-login user gets a membership via `ensure_membership!`).

- [ ] **Step 6: Commit**

```bash
git add lib/cympho_web/user_auth.ex lib/cympho_web/router.ex test/cympho_web/require_company_gate_test.exs
git commit -m "Gate app behind company membership; company-less users go to onboarding"
```

---

### Task 4: First-run `/setup` + zero-user login redirect

**Files:**
- Create: `lib/cympho_web/controllers/setup_controller.ex`
- Modify: `lib/cympho_web/controllers/session_controller.ex` (`new/2`)
- Modify: `lib/cympho_web/router.ex` (public routes)
- Test: `test/cympho_web/controllers/setup_controller_test.exs` (create)
- Modify: `test/cympho_web/controllers/session_controller_test.exs` (two `get /login` tests)

- [ ] **Step 1: Write the failing tests**

`test/cympho_web/controllers/setup_controller_test.exs` (async: false — the advisory lock plus global user-count reads keep this serial):

```elixir
defmodule CymphoWeb.SetupControllerTest do
  use CymphoWeb.ConnCase, async: false

  defp seed_user! do
    {:ok, user} =
      Cympho.Users.create_user(%{
        email: "existing-#{System.unique_integer([:positive])}@example.com",
        name: "Existing",
        password: "password1234"
      })

    user
  end

  test "GET /setup renders the owner form when no users exist", %{conn: conn} do
    conn = get(conn, "/setup")
    assert html_response(conn, 200) =~ "Create your owner account"
  end

  test "GET /setup redirects to login once a user exists", %{conn: conn} do
    seed_user!()
    assert redirected_to(get(conn, "/setup")) == "/login"
  end

  test "GET /login redirects to setup when no users exist", %{conn: conn} do
    assert redirected_to(get(conn, "/login")) == "/setup"
  end

  test "POST /setup creates the owner, signs them in, and sends them to onboarding", %{conn: conn} do
    conn =
      post(conn, "/setup", %{
        "user" => %{"name" => "Nick", "email" => "nick@example.com", "password" => "longenough1"}
      })

    assert redirected_to(conn) == "/onboarding"
    assert {:ok, user} = Cympho.Users.get_user_by_email("nick@example.com")
    assert Plug.Conn.get_session(conn, :user_id) == user.id
  end

  test "POST /setup refuses once a user exists", %{conn: conn} do
    seed_user!()

    conn =
      post(conn, "/setup", %{
        "user" => %{"name" => "Late", "email" => "late@example.com", "password" => "longenough1"}
      })

    assert redirected_to(conn) == "/login"
    assert {:error, :not_found} = Cympho.Users.get_user_by_email("late@example.com")
  end

  test "POST /setup re-renders with errors on invalid input", %{conn: conn} do
    conn =
      post(conn, "/setup", %{
        "user" => %{"name" => "Nick", "email" => "nick@example.com", "password" => "short"}
      })

    assert html_response(conn, 200) =~ "at least 8 characters"
    assert {:error, :not_found} = Cympho.Users.get_user_by_email("nick@example.com")
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/cympho_web/controllers/setup_controller_test.exs`
Expected: FAIL — no `/setup` route.

- [ ] **Step 3: Create `lib/cympho_web/controllers/setup_controller.ex`**

```elixir
defmodule CymphoWeb.SetupController do
  @moduledoc """
  One-time first-run setup: creates the instance owner when the user table is
  empty, then hands off to /onboarding. Locks itself permanently once any user
  exists (guarded by a Postgres advisory lock against concurrent submits).
  """

  use CymphoWeb, :controller

  alias Cympho.Authentication
  alias Cympho.Repo
  alias Cympho.Users.User
  alias CymphoWeb.SessionController

  @setup_lock_key 7_214_001

  def new(conn, _params) do
    if users_exist?() do
      redirect(conn, to: "/login")
    else
      conn |> put_layout(false) |> html(setup_page(%{}, nil))
    end
  end

  def create(conn, %{"user" => user_params}) do
    case create_first_user(user_params) do
      {:ok, user} ->
        conn
        |> SessionController.sign_in(user)
        |> put_flash(:info, "Welcome! Let's set up your company.")
        |> redirect(to: "/onboarding")

      {:error, :already_configured} ->
        redirect(conn, to: "/login")

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_layout(false)
        |> html(setup_page(user_params, first_error(changeset)))
    end
  end

  def create(conn, _params), do: redirect(conn, to: "/setup")

  defp users_exist?, do: Repo.aggregate(User, :count) > 0

  defp create_first_user(params) do
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock($1)", [@setup_lock_key])

      if users_exist?() do
        Repo.rollback(:already_configured)
      else
        case Authentication.register_user(%{
               "name" => params["name"],
               "email" => params["email"],
               "password" => params["password"]
             }) do
          {:ok, user} -> user
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end
    end)
  end

  defp first_error(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map(fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
    |> List.first()
  end

  defp setup_page(params, error) do
    csrf = Plug.CSRFProtection.get_csrf_token()
    error_html = if error, do: ~s(<p class="error">#{escape(error)}</p>), else: ""

    """
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <link rel="icon" type="image/svg+xml" href="/images/favicon.svg">
        <title>Set up · Cympho</title>
        <style>
          :root { color-scheme: dark; font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background: #20201E; color: #FAF9F5; }
          body { min-height: 100dvh; margin: 0; display: grid; place-items: center; background: radial-gradient(900px 480px at 50% -120px, rgba(217, 119, 87, .18), transparent 70%), #20201E; }
          main { width: min(420px, calc(100vw - 32px)); border: 1px solid rgba(255,250,245,.10); border-radius: 20px; background: rgba(38, 38, 36, .96); box-shadow: inset 0 1px 0 0 rgba(255,250,245,.05), 0 24px 80px rgba(0,0,0,.42); animation: enter 700ms cubic-bezier(0.16,1,0.3,1) both; }
          @keyframes enter { from { opacity: 0; transform: translateY(14px) scale(.98); } to { opacity: 1; transform: none; } }
          @media (prefers-reduced-motion: reduce) { main { animation: none; } }
          form { display: grid; gap: 14px; padding: 30px; }
          .mark { display: inline-flex; align-items: center; gap: 8px; color: #D97757; font-size: 13px; font-weight: 620; letter-spacing: .08em; text-transform: uppercase; }
          .mark svg { width: 14px; height: 14px; }
          h1 { margin: 6px 0 0; font-family: "Source Serif 4", Georgia, "Times New Roman", serif; font-size: 27px; line-height: 1.15; font-weight: 600; letter-spacing: -0.3px; }
          p { margin: 6px 0 0; color: #B0A99C; font-size: 14px; line-height: 1.5; }
          label { display: grid; gap: 7px; color: #E5E1D8; font-size: 13px; font-weight: 560; }
          input { width: 100%; box-sizing: border-box; border: 1px solid rgba(255,250,245,.12); border-radius: 10px; background: #2D2C2A; color: #FAF9F5; padding: 10px 11px; font: inherit; transition: border-color 160ms ease, box-shadow 160ms ease; }
          input:focus { outline: none; border-color: rgba(217,119,87,.75); box-shadow: 0 0 0 3px rgba(217,119,87,.22); }
          button { border: 0; border-radius: 10px; background: #D97757; color: #20201E; padding: 11px 12px; font: inherit; font-weight: 620; cursor: pointer; box-shadow: inset 0 1px 0 0 rgba(255,255,255,.18); transition: background 160ms ease; }
          button:hover { background: #E08A6B; }
          .error { color: #E0AEAE; background: rgba(198, 69, 69, .12); border: 1px solid rgba(198, 69, 69, .26); border-radius: 8px; padding: 9px 10px; }
        </style>
      </head>
      <body>
        <main>
          <form method="post" action="/setup">
            <input type="hidden" name="_csrf_token" value="#{csrf}">
            <div>
              <span class="mark">
                <svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M12 2 L13.8 10.2 L22 12 L13.8 13.8 L12 22 L10.2 13.8 L2 12 L10.2 10.2 Z"/></svg>
                Cympho
              </span>
              <h1>Create your owner account</h1>
              <p>This instance is brand new. Create the owner account, then the setup wizard will launch your first autonomous company.</p>
            </div>
            #{error_html}
            <label>
              Name
              <input name="user[name]" type="text" autocomplete="name" value="#{escape(params["name"])}" required>
            </label>
            <label>
              Email
              <input name="user[email]" type="email" autocomplete="email" value="#{escape(params["email"])}" required>
            </label>
            <label>
              Password
              <input name="user[password]" type="password" autocomplete="new-password" minlength="8" required>
            </label>
            <button type="submit">Create owner account</button>
          </form>
        </main>
      </body>
    </html>
    """
  end

  defp escape(value) when is_binary(value),
    do: Phoenix.HTML.html_escape(value) |> Phoenix.HTML.safe_to_string()

  defp escape(_), do: ""
end
```

- [ ] **Step 4: Route + login redirect**

In `lib/cympho_web/router.ex`, public `:browser` scope, next to the `/login` routes:

```elixir
    get "/setup", SetupController, :new
    post "/setup", SetupController, :create
```

In `lib/cympho_web/controllers/session_controller.ex`, replace `new/2` with:

```elixir
  def new(conn, params) do
    if Repo.aggregate(User, :count) == 0 do
      # Fresh instance: no owner yet — send the visitor to first-run setup
      # instead of a login form nobody can pass.
      redirect(conn, to: "/setup")
    else
      conn
      |> put_layout(false)
      |> html(sign_in_page(params, Phoenix.Flash.get(conn.assigns.flash, :error)))
    end
  end
```

- [ ] **Step 5: Fix the two zero-user `/login` tests**

In `test/cympho_web/controllers/session_controller_test.exs`, the tests `"renders a safe return target into the sign-in form"` and `"drops unsafe return targets from the sign-in form"` must seed a user first — add `registered_user()` as the first line of each (helper already defined in that file).

- [ ] **Step 6: Run tests**

Run: `mix test test/cympho_web/controllers/setup_controller_test.exs test/cympho_web/controllers/session_controller_test.exs`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add lib/cympho_web/controllers/setup_controller.ex lib/cympho_web/controllers/session_controller.ex lib/cympho_web/router.ex test/cympho_web/controllers/setup_controller_test.exs test/cympho_web/controllers/session_controller_test.exs
git commit -m "Add first-run /setup owner creation and zero-user login redirect"
```

---

### Task 5: Invite-only `/api/register`

**Files:**
- Modify: `lib/cympho_web/controllers/registration_controller.ex`
- Modify: `config/dev.exs`
- Test: `test/cympho_web/controllers/registration_controller_test.exs` (create)

- [ ] **Step 1: Write the failing tests** (async: false — mutates global app env)

```elixir
defmodule CymphoWeb.RegistrationControllerTest do
  use CymphoWeb.ConnCase, async: false

  @params %{"user" => %{"name" => "New", "email" => "new@example.com", "password" => "longenough1"}}

  test "returns 403 when registration is closed (default)", %{conn: conn} do
    conn = post(conn, "/api/register", @params)
    assert json_response(conn, 403)["error"] == "registration is invite-only"
    assert {:error, :not_found} = Cympho.Users.get_user_by_email("new@example.com")
  end

  test "creates a user when open_registration is enabled", %{conn: conn} do
    Application.put_env(:cympho, :open_registration, true)
    on_exit(fn -> Application.delete_env(:cympho, :open_registration) end)

    conn = post(conn, "/api/register", @params)
    assert json_response(conn, 201)
    assert {:ok, _user} = Cympho.Users.get_user_by_email("new@example.com")
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/cympho_web/controllers/registration_controller_test.exs`
Expected: first test FAILS (currently 201)

- [ ] **Step 3: Implement**

In `lib/cympho_web/controllers/registration_controller.ex`, wrap `create/2`:

```elixir
  def create(conn, %{"user" => user_params}) do
    if Application.get_env(:cympho, :open_registration, false) do
      do_create(conn, user_params)
    else
      conn
      |> put_status(:forbidden)
      |> json(%{error: "registration is invite-only"})
    end
  end

  defp do_create(conn, user_params) do
    case Authentication.register_user(user_params) do
      {:ok, %User{} = user} ->
        conn
        |> put_status(:created)
        |> render(:show, user: user)

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> put_view(json: CymphoWeb.ErrorJSON)
        |> render(:error, changeset: changeset)
    end
  end
```

In `config/dev.exs` add:

```elixir
# Open self-registration is a dev convenience; production is invite-only.
config :cympho, open_registration: true
```

- [ ] **Step 4: Run tests**

Run: `mix test test/cympho_web/controllers/registration_controller_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/cympho_web/controllers/registration_controller.ex config/dev.exs test/cympho_web/controllers/registration_controller_test.exs
git commit -m "Make /api/register invite-only outside dev"
```

---

### Task 6: Onboarding wizard rebuild (6 steps)

**Files:**
- Modify: `lib/cympho_web/live/onboarding_live/index.ex` (rewrite module internals)
- Modify: `lib/cympho_web/live/onboarding_live/index.html.heex` (restructure)
- Modify: `test/cympho_web/live/onboarding_live_test.exs` (rewrite walk-through)

Step map: 0 welcome · 1 blueprint · 2 company · 3 team · 4 launch · 5 ready.

- [ ] **Step 1: Rewrite the LiveView module**

Replace the module body of `lib/cympho_web/live/onboarding_live/index.ex` with (keeping `role_label/1` and `filter_blueprints/2` as-is):

```elixir
defmodule CymphoWeb.OnboardingLive.Index do
  use CymphoWeb, :live_view

  alias Cympho.Agents.Agent
  alias Cympho.Companies

  @steps [
    %{
      id: :welcome,
      title: "Start an autonomous company",
      description: "Create a CEO, CTO, engineers, goal, project, and first issues"
    },
    %{
      id: :blueprint,
      title: "Choose a blueprint",
      description: "Pick the kind of company your agents will run"
    },
    %{
      id: :company,
      title: "Name the company",
      description: "Set the company name, goal, and issue prefix"
    },
    %{
      id: :team,
      title: "Build the team",
      description: "CEO and CTO lead by default — configure your engineers and runtime"
    },
    %{
      id: :launch,
      title: "Review and launch",
      description: "Confirm the plan — launch creates everything in one transaction"
    },
    %{
      id: :ready,
      title: "You're all set!",
      description: "Your autonomous company is live"
    }
  ]

  @impl true
  def mount(_params, _session, socket) do
    blueprints = Companies.autonomous_company_blueprints()

    socket =
      socket
      |> assign(:page_title, "Get Started")
      |> assign(:steps, @steps)
      |> assign(:blueprints, blueprints)
      |> assign(:blueprint_query, "")
      |> assign(:filtered_blueprints, blueprints)
      |> assign(:current_step, 0)
      |> assign(:step_error, nil)
      |> assign(:bootstrap_result, nil)
      |> assign(:company_form, %{
        "blueprint" => "software",
        "name" => "Autonomous Software Company",
        "goal_title" => "Build and run the business autonomously",
        "issue_prefix" => "LLM",
        "engineer_count" => "2",
        "engineer_names" => [],
        "adapter" => "claude_code",
        "runtime_command" => "",
        "runtime_model" => ""
      })

    {:ok, socket}
  end

  @impl true
  def handle_event("next_step", _params, socket) do
    step = Enum.at(socket.assigns.steps, socket.assigns.current_step)

    case validate_step(step.id, socket.assigns.company_form) do
      :ok ->
        max = length(socket.assigns.steps) - 1
        next = min(socket.assigns.current_step + 1, max)
        {:noreply, socket |> assign(:current_step, next) |> assign(:step_error, nil)}

      {:error, message} ->
        {:noreply, assign(socket, :step_error, message)}
    end
  end

  def handle_event("prev_step", _params, socket) do
    {:noreply,
     socket
     |> assign(:current_step, max(socket.assigns.current_step - 1, 0))
     |> assign(:step_error, nil)}
  end

  def handle_event("skip", _params, socket) do
    if socket.assigns[:current_company] do
      {:noreply, push_navigate(socket, to: ~p"/issues")}
    else
      {:noreply, assign(socket, :step_error, "Finish setup to enter Cympho.")}
    end
  end

  def handle_event("update_company_form", %{"company" => params}, socket) do
    params = maybe_apply_blueprint_defaults(params, socket.assigns.company_form)
    form = Map.merge(socket.assigns.company_form, params)
    {:noreply, socket |> assign(:company_form, form) |> assign(:step_error, nil)}
  end

  def handle_event("filter_blueprints", %{"blueprint_query" => query}, socket) do
    query = String.trim(query || "")

    {:noreply,
     socket
     |> assign(:blueprint_query, query)
     |> assign(:filtered_blueprints, filter_blueprints(socket.assigns.blueprints, query))}
  end

  def handle_event("start_autonomous_company", _params, socket) do
    form = socket.assigns.company_form

    with :ok <- validate_step(:company, form) do
      attrs = %{
        "blueprint" => form["blueprint"],
        "name" => form["name"],
        "goal_title" => form["goal_title"],
        "issue_prefix" => form["issue_prefix"],
        "engineer_count" => engineer_count(form),
        "engineer_names" => form["engineer_names"] || [],
        "adapter" => form["adapter"],
        "agent_runtime" => %{
          "command" => form["runtime_command"],
          "model" => form["runtime_model"]
        },
        "owner_user_id" => socket.assigns.current_user.id
      }

      case Companies.create_autonomous_company(attrs) do
        {:ok, result} ->
          {:noreply,
           socket
           |> assign(:bootstrap_result, result)
           |> assign(:step_error, nil)
           |> assign(:current_step, 5)}

        {:error, reason} ->
          {:noreply, assign(socket, :step_error, "Could not create company: #{inspect(reason)}")}
      end
    else
      {:error, message} ->
        {:noreply, socket |> assign(:current_step, 2) |> assign(:step_error, message)}
    end
  end

  def engineer_count(form) do
    case Integer.parse(to_string(form["engineer_count"] || "2")) do
      {count, _} -> count |> max(0) |> min(8)
      :error -> 2
    end
  end

  def engineer_name_value(form, index) do
    case Enum.at(form["engineer_names"] || [], index - 1) do
      name when is_binary(name) and name != "" -> name
      _ -> "Engineer #{index}"
    end
  end

  def selected_blueprint(blueprints, form) do
    Enum.find(blueprints, &(&1.key == form["blueprint"])) || List.first(blueprints)
  end

  defp validate_step(:company, form) do
    cond do
      String.trim(form["name"] || "") == "" ->
        {:error, "Company name is required."}

      not Regex.match?(~r/^[A-Z]{2,10}$/, form["issue_prefix"] || "") ->
        {:error, "Issue prefix must be 2-10 uppercase letters."}

      true ->
        :ok
    end
  end

  defp validate_step(_step, _form), do: :ok

  defp maybe_apply_blueprint_defaults(params, current_form) do
    selected = params["blueprint"] || current_form["blueprint"] || "software"
    previous = current_form["blueprint"] || "software"

    if selected != previous do
      case Companies.autonomous_company_blueprint(selected) do
        {:ok, blueprint} ->
          params
          |> Map.put("blueprint", selected)
          |> Map.put("goal_title", blueprint.default_goal)
          |> Map.put("issue_prefix", blueprint.default_prefix)

        {:error, :not_found} ->
          params
      end
    else
      Map.put_new(params, "blueprint", selected)
    end
  end

  defp filter_blueprints(blueprints, ""), do: blueprints

  defp filter_blueprints(blueprints, query) do
    normalized_query = String.downcase(query)

    Enum.filter(blueprints, fn blueprint ->
      [
        blueprint.key,
        blueprint.name,
        blueprint.description,
        blueprint.default_goal,
        blueprint.role_summary,
        Enum.join(blueprint.roles, " "),
        Enum.join(blueprint.capability_tags, " "),
        Enum.join(blueprint.seed_issue_titles, " ")
      ]
      |> Enum.join(" ")
      |> String.downcase()
      |> String.contains?(normalized_query)
    end)
  end

  defp role_label(role), do: Agent.role_label(role)

  # What the operator walks away with after each step — states the payoff, not
  # just the inputs, so the wizard feels like progress rather than a form.
  defp step_outcome(:welcome),
    do: "A few quick choices set up a CEO, CTO, specialist agents, a goal, a project, and seed issues."

  defp step_outcome(:blueprint),
    do: "The blueprint decides which agents get hired and what their first issues are."

  defp step_outcome(:company),
    do: "The prefix becomes your issue IDs (like ACME-1); the goal is what the CEO decomposes."

  defp step_outcome(:team),
    do: "CEO and CTO are always created. Engineers do the hands-on work — name them and pick their runtime."

  defp step_outcome(:launch),
    do: "One transaction creates the company, your owner seat, all agents, the goal, project, and first issues."

  defp step_outcome(:ready), do: "Everything below is live. Enter Cympho to start working."
  defp step_outcome(_), do: nil
end
```

- [ ] **Step 2: Restructure the template**

Edit `lib/cympho_web/live/onboarding_live/index.html.heex`:

2a. **Keep unchanged:** the outer wrapper, progress dots, step header block (lines 1–36 today), and the welcome-step div (`:if={@current_step == 0}`, lines 39–123 today).

2b. **Insert an error banner** right after the step-header block (before the step divs):

```heex
      <div
        :if={@step_error}
        class="mb-4 rounded-lg border border-red-500/40 bg-red-500/10 px-4 py-2.5 text-sm text-red-300"
      >
        {@step_error}
      </div>
```

2c. **Blueprint step** (`:if={@current_step == 1}`): keep the existing `#blueprint-search-form` block exactly as-is, then the blueprint radio grid (currently inside `#company-starter-form`) wrapped in its own form — the radio grid markup, selected-state classes, and empty-state div are reused verbatim from the current file:

```heex
      <div :if={@current_step == 1} class="ember-glass p-6 mb-6">
        <!-- existing #blueprint-search-form block, unchanged -->
        <form id="blueprint-form" phx-change="update_company_form">
          <div class="mb-2 flex items-center justify-between gap-3">
            <label class="block text-xs font-510 text-text-tertiary">Company blueprint</label>
            <span class="text-[11px] text-text-quaternary">Creates agents and first issues</span>
          </div>
          <!-- existing radio grid + empty state, unchanged, still name="company[blueprint]" -->
        </form>
      </div>
```

2d. **Company step** (`:if={@current_step == 2}`): the name/goal/prefix inputs from the old workspace form, in their own form (no submit button, no engineer count):

```heex
      <div :if={@current_step == 2} class="ember-glass p-6 mb-6">
        <form id="company-step-form" phx-change="update_company_form" class="space-y-4">
          <div>
            <label class="block text-xs font-510 text-text-tertiary mb-1.5">Company name</label>
            <input
              name="company[name]"
              value={@company_form["name"]}
              class="w-full rounded-lg border border-border bg-surface px-3 py-2 text-sm text-text-primary placeholder:text-text-quaternary focus:border-accent focus:outline-none"
            />
          </div>
          <div>
            <label class="block text-xs font-510 text-text-tertiary mb-1.5">Company goal</label>
            <textarea
              name="company[goal_title]"
              rows="3"
              class="w-full rounded-lg border border-border bg-surface px-3 py-2 text-sm text-text-primary placeholder:text-text-quaternary focus:border-accent focus:outline-none"
            >{@company_form["goal_title"]}</textarea>
          </div>
          <div class="max-w-[200px]">
            <label class="block text-xs font-510 text-text-tertiary mb-1.5">Issue prefix</label>
            <input
              name="company[issue_prefix]"
              value={@company_form["issue_prefix"]}
              maxlength="10"
              class="w-full rounded-lg border border-border bg-surface px-3 py-2 text-sm text-text-primary focus:border-accent focus:outline-none"
            />
          </div>
        </form>
      </div>
```

2e. **Team step** (`:if={@current_step == 3}`):

```heex
      <div :if={@current_step == 3} class="ember-glass p-6 mb-6">
        <div class="mb-5 grid gap-2 sm:grid-cols-2">
          <div class="rounded-lg border border-brand/40 bg-brand/10 px-4 py-3">
            <p class="text-sm font-590 text-text-primary">CEO</p>
            <p class="mt-0.5 text-xs text-text-tertiary">
              Owns the goal, decomposes strategy, delegates. Always created.
            </p>
          </div>
          <div class="rounded-lg border border-brand/40 bg-brand/10 px-4 py-3">
            <p class="text-sm font-590 text-text-primary">CTO</p>
            <p class="mt-0.5 text-xs text-text-tertiary">
              Turns strategy into technical plans and reviews the work. Always created.
            </p>
          </div>
        </div>
        <p class="mb-4 text-xs text-text-quaternary">
          Blueprint roster: {selected_blueprint(@blueprints, @company_form).role_summary}
        </p>

        <form id="team-step-form" phx-change="update_company_form" class="space-y-4">
          <div class="max-w-[200px]">
            <label class="block text-xs font-510 text-text-tertiary mb-1.5">Engineers</label>
            <input
              type="number"
              min="0"
              max="8"
              name="company[engineer_count]"
              value={@company_form["engineer_count"]}
              class="w-full rounded-lg border border-border bg-surface px-3 py-2 text-sm text-text-primary focus:border-accent focus:outline-none"
            />
          </div>
          <div :if={engineer_count(@company_form) > 0} class="grid gap-2 sm:grid-cols-2">
            <div :for={index <- 1..engineer_count(@company_form)}>
              <label class="block text-xs font-510 text-text-tertiary mb-1.5">
                Engineer {index} name
              </label>
              <input
                name="company[engineer_names][]"
                value={engineer_name_value(@company_form, index)}
                class="w-full rounded-lg border border-border bg-surface px-3 py-2 text-sm text-text-primary focus:border-accent focus:outline-none"
              />
            </div>
          </div>

          <fieldset class="rounded-lg border border-border p-4">
            <legend class="px-1 text-xs font-510 text-text-tertiary">Agent runtime</legend>
            <div class="grid gap-3 sm:grid-cols-3">
              <div>
                <label class="block text-xs font-510 text-text-tertiary mb-1.5">Adapter</label>
                <select
                  name="company[adapter]"
                  class="w-full rounded-lg border border-border bg-surface px-3 py-2 text-sm text-text-primary focus:border-accent focus:outline-none"
                >
                  {Phoenix.HTML.Form.options_for_select(
                    [
                      {"Claude Code", "claude_code"},
                      {"Codex", "codex"},
                      {"Cursor", "cursor"},
                      {"HTTP", "http"}
                    ],
                    @company_form["adapter"]
                  )}
                </select>
              </div>
              <div>
                <label class="block text-xs font-510 text-text-tertiary mb-1.5">Command</label>
                <input
                  name="company[runtime_command]"
                  value={@company_form["runtime_command"]}
                  placeholder="claude (default)"
                  class="w-full rounded-lg border border-border bg-surface px-3 py-2 text-sm text-text-primary placeholder:text-text-quaternary focus:border-accent focus:outline-none"
                />
              </div>
              <div>
                <label class="block text-xs font-510 text-text-tertiary mb-1.5">Model</label>
                <input
                  name="company[runtime_model]"
                  value={@company_form["runtime_model"]}
                  placeholder="provider default"
                  class="w-full rounded-lg border border-border bg-surface px-3 py-2 text-sm text-text-primary placeholder:text-text-quaternary focus:border-accent focus:outline-none"
                />
              </div>
            </div>
            <p class="mt-2 text-[11px] leading-4 text-text-quaternary">
              Applies to every agent. Command can be a Claude-compatible wrapper (e.g. cz); model is exported as ANTHROPIC_MODEL.
            </p>
          </fieldset>
        </form>
      </div>
```

2f. **Launch step** (`:if={@current_step == 4}`):

```heex
      <div :if={@current_step == 4} class="ember-glass card-lift p-6 mb-6">
        <div class="stagger-children space-y-2 text-sm">
          <div class="flex items-center justify-between py-1.5 px-3 rounded-lg bg-surface">
            <span class="text-text-secondary">Company</span>
            <span class="text-text-primary font-590">{@company_form["name"]}</span>
          </div>
          <div class="flex items-center justify-between py-1.5 px-3 rounded-lg bg-surface">
            <span class="text-text-secondary">Blueprint</span>
            <span class="text-text-primary font-590">
              {selected_blueprint(@blueprints, @company_form).name}
            </span>
          </div>
          <div class="flex items-center justify-between gap-3 py-1.5 px-3 rounded-lg bg-surface">
            <span class="text-text-secondary">Goal</span>
            <span class="max-w-[280px] truncate text-text-primary" title={@company_form["goal_title"]}>
              {@company_form["goal_title"]}
            </span>
          </div>
          <div class="flex items-center justify-between py-1.5 px-3 rounded-lg bg-surface">
            <span class="text-text-secondary">Issue prefix</span>
            <span class="text-text-primary font-mono font-590">{@company_form["issue_prefix"]}</span>
          </div>
          <div class="flex items-center justify-between gap-3 py-1.5 px-3 rounded-lg bg-surface">
            <span class="text-text-secondary">Engineers</span>
            <span class="max-w-[280px] truncate text-text-primary font-590">
              {engineer_count(@company_form)}<span :if={engineer_count(@company_form) > 0}>
                · {Enum.map_join(1..engineer_count(@company_form), ", ", &engineer_name_value(@company_form, &1))}</span>
            </span>
          </div>
          <div class="flex items-center justify-between py-1.5 px-3 rounded-lg bg-surface">
            <span class="text-text-secondary">Runtime</span>
            <span class="text-text-primary font-590">
              {@company_form["adapter"]}
              · {if @company_form["runtime_command"] not in [nil, ""], do: @company_form["runtime_command"], else: "default command"}
              · {if @company_form["runtime_model"] not in [nil, ""], do: @company_form["runtime_model"], else: "default model"}
            </span>
          </div>
        </div>
        <button
          type="button"
          phx-click="start_autonomous_company"
          phx-disable-with="Launching..."
          class="mt-5 w-full cta-glow rounded-button bg-brand px-4 py-2.5 text-sm font-510 text-on-primary hover:bg-accent-hover transition-colors"
        >
          Launch autonomous company
        </button>
      </div>
```

2g. **Ready step**: change the condition to `:if={@current_step == 5}` and keep the existing bootstrap_result summary body; insert the shortcuts rows (the current step-2 `.stagger-children` shortcuts block) below the summary; replace the two bottom links with:

```heex
          <div class="flex gap-3 w-full pt-2">
            <.link
              :if={@bootstrap_result}
              href={"/switch-company/#{@bootstrap_result.company.id}?return_to=/issues"}
              class="flex-1 text-center cta-glow bg-brand hover:bg-accent text-on-primary font-590 text-sm px-4 py-2.5 rounded-button transition-colors"
            >
              Enter Cympho
            </.link>
          </div>
```

(`href`, not `navigate` — `/switch-company/:id` is a controller route that writes the session `company_id`, then bounces to `/issues`.)

Delete the old standalone shortcuts step div.

2h. **Footer nav** — replace the nav-buttons block with:

```heex
      <div class="flex items-center justify-between">
        <button
          :if={@current_step > 0 && @current_step < 5}
          type="button"
          phx-click="prev_step"
          class="text-sm text-text-tertiary hover:text-text-secondary transition-colors px-3 py-2 min-h-[44px]"
        >
          Back
        </button>
        <button
          :if={@current_step == 0 && @current_company}
          type="button"
          phx-click="skip"
          class="text-sm text-text-quaternary hover:text-text-tertiary transition-colors px-3 py-2 min-h-[44px]"
        >
          Skip setup
        </button>
        <div class="flex items-center gap-3 ml-auto">
          <span class="text-xs text-text-quaternary">
            {@current_step + 1} of {length(@steps)}
          </span>
          <button
            :if={@current_step < 4}
            type="button"
            phx-click="next_step"
            class="cta-glow bg-brand hover:bg-accent text-on-primary font-510 text-sm px-5 py-2.5 rounded-button transition-colors min-h-[44px]"
          >
            Continue
          </button>
        </div>
      </div>
```

(The `nav_cta_class/1` helper is deleted from the module — the launch and ready steps carry their own primary CTAs.)

- [ ] **Step 3: Rewrite the wizard walk-through test**

Replace the first test in `test/cympho_web/live/onboarding_live_test.exs` (keep the filter test — it still works: one Continue click reaches the blueprint step):

```elixir
    test "walks the wizard and launches a company with owner, engineers, and runtime", %{
      conn: conn
    } do
      {:ok, view, html} = live(conn, "/onboarding")
      assert html =~ "Start an autonomous company"

      # welcome -> blueprint
      html = view |> element("button", "Continue") |> render_click()
      assert html =~ "Company blueprint"

      view
      |> form("#blueprint-form", company: %{"blueprint" => "software"})
      |> render_change()

      # blueprint -> company
      view |> element("button", "Continue") |> render_click()

      view
      |> form("#company-step-form",
        company: %{
          "name" => "Wizard Co",
          "goal_title" => "Ship the wizard",
          "issue_prefix" => "WIZ"
        }
      )
      |> render_change()

      # company -> team
      html = view |> element("button", "Continue") |> render_click()
      assert html =~ "CEO"
      assert html =~ "CTO"

      view
      |> form("#team-step-form",
        company: %{
          "engineer_count" => "2",
          "engineer_names" => ["Ada", "Grace"],
          "adapter" => "claude_code",
          "runtime_command" => "cz",
          "runtime_model" => "claude-sonnet-5"
        }
      )
      |> render_change()

      # team -> launch
      html = view |> element("button", "Continue") |> render_click()
      assert html =~ "Launch autonomous company"
      assert html =~ "Ada"

      html = view |> element("button", "Launch autonomous company") |> render_click()
      assert html =~ "You&#39;re all set!" or html =~ "You're all set!"
      assert html =~ "Enter Cympho"

      company = Companies.get_company_by_slug("wizard-co")
      assert company

      # The signed-in LiveCase user must own the new company. list_memberships/1
      # preloads :user, so we can assert identity without a LiveCase helper.
      assert [membership] = Companies.list_memberships(company.id)
      assert membership.role == "owner"
      assert membership.is_board_member
      assert membership.user.email =~ "live-user-"

      agents = Companies.list_company_agents(company.id)
      engineer_names = agents |> Enum.filter(&(&1.role == :engineer)) |> Enum.map(& &1.name)
      assert Enum.sort(engineer_names) == ["Ada", "Grace"]

      for agent <- agents do
        assert agent.runtime_config["command"] == "cz"
        assert agent.runtime_config["env"]["ANTHROPIC_MODEL"] == "claude-sonnet-5"
      end
    end

    test "blocks the company step on an invalid issue prefix", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/onboarding")

      view |> element("button", "Continue") |> render_click()
      view |> element("button", "Continue") |> render_click()

      view
      |> form("#company-step-form", company: %{"name" => "Bad Prefix Co", "issue_prefix" => "bad"})
      |> render_change()

      html = view |> element("button", "Continue") |> render_click()
      assert html =~ "Issue prefix must be 2-10 uppercase letters."
    end
```

Also update the old first test's expectations if kept anywhere: the single `#company-starter-form` no longer exists. Note the LiveCase user already has a company ("Live Co N"), so `skip` and the gate don't interfere with these tests; launching creates a second company for that user, which is fine.

- [ ] **Step 4: Run onboarding tests**

Run: `mix test test/cympho_web/live/onboarding_live_test.exs`
Expected: PASS (walk-through, prefix validation, filter test)

- [ ] **Step 5: Commit**

```bash
git add lib/cympho_web/live/onboarding_live/ test/cympho_web/live/onboarding_live_test.exs
git commit -m "Rebuild onboarding as a six-step wizard with team and runtime config"
```

---

### Task 7: Verification sweep

- [ ] **Step 1: Format + full suite**

Run: `mix format && mix test`
Expected: no diff from format (or commit formatting), all tests PASS.

- [ ] **Step 2: Manual smoke in dev (fresh DB)**

Run: `mix ecto.reset && mix phx.server` — seeds create a company but **no users**, so visiting `http://localhost:4000/login` must redirect to `/setup`. Create an owner, complete the wizard (2 engineers named, command `cz`, model set), land on `/issues`, confirm the sidebar shows the project and agents. Then verify `iex` check:

```elixir
Cympho.Repo.all(Cympho.Agents.Agent) |> Enum.map(& &1.runtime_config)
```

Expected: every launched agent carries `"command" => "cz"` and `"env" => %{"ANTHROPIC_MODEL" => ...}`.

- [ ] **Step 3: Commit any fixes, then push checkpoint commit**

```bash
git add -A && git commit -m "First-run setup and onboarding wizard" || true
```

---

### Task 8: Deploy A + production onboarding (ops checkpoint)

**Pre-condition:** the NOT NULL migration (Task 9) must NOT exist in the working tree yet — deploy.sh rsyncs the tree, and production still has an orphan project with zero companies, so the migration would abort the deploy.

- [ ] **Step 1: Deploy**

Run: `CYMPHO_DEPLOY_PASSWORD='<ssh password>' ./deploy.sh`
Expected: `Deployment complete`, public check OK.

- [ ] **Step 2: Verify gates on prod**

- `curl -s -o /dev/null -w '%{redirect_url}' https://cympho.llmotions.com/login` → stays on login (a user exists).
- Logging in as nick@hack.ski must land on `/onboarding` (no company yet).

- [ ] **Step 3: HUMAN CHECKPOINT — Nick completes the wizard on production.**

After completion, verify over ssh:

```bash
docker exec cympho-db psql -U cympho -d cympho -c \
  "select c.name, m.role, m.is_board_member from companies c join company_memberships m on m.company_id = c.id;"
```

Expected: one company, membership role `owner`, board member `t`.

---

### Task 9: Orphan adoption + NOT NULL migration (Deploy B)

**Files:**
- Create: `priv/repo/migrations/20260715000000_require_company_on_projects.exs`

- [ ] **Step 1: Write the migration**

```elixir
defmodule Cympho.Repo.Migrations.RequireCompanyOnProjects do
  use Ecto.Migration

  def up do
    # Adopt legacy orphan projects (created before the company gate existed)
    # into the oldest company, then lock the column. Fails loudly if orphans
    # exist with no company to adopt them — create a company first.
    execute """
    DO $$
    DECLARE
      adopt_company_id uuid;
      orphan_count integer;
    BEGIN
      SELECT count(*) INTO orphan_count FROM projects WHERE company_id IS NULL;
      IF orphan_count > 0 THEN
        SELECT id INTO adopt_company_id
          FROM companies ORDER BY inserted_at ASC, id ASC LIMIT 1;
        IF adopt_company_id IS NULL THEN
          RAISE EXCEPTION 'orphan projects exist but no company to adopt them';
        END IF;
        UPDATE projects SET company_id = adopt_company_id WHERE company_id IS NULL;
      END IF;
    END $$;
    """

    execute "ALTER TABLE projects ALTER COLUMN company_id SET NOT NULL"
  end

  def down do
    execute "ALTER TABLE projects ALTER COLUMN company_id DROP NOT NULL"
  end
end
```

- [ ] **Step 2: Verify locally**

Run: `mix ecto.reset && mix test`
Expected: migration applies cleanly on a fresh DB (no orphans → no-op backfill), suite PASSES.

- [ ] **Step 3: Commit**

```bash
git add priv/repo/migrations/20260715000000_require_company_on_projects.exs
git commit -m "Adopt orphan projects and require company_id at the DB level"
```

- [ ] **Step 4: Deploy B**

Run: `CYMPHO_DEPLOY_PASSWORD='<ssh password>' ./deploy.sh`
Expected: migration runs during deploy; `Deployment complete`.

- [ ] **Step 5: Verify adoption on prod**

```bash
docker exec cympho-db psql -U cympho -d cympho -c \
  "select name, prefix, company_id is not null as adopted from projects;"
```

Expected: `AILogic | AILGC | t` (plus the wizard-created project), and it now appears in Nick's sidebar.
