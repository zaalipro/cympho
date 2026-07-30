defmodule Cympho.CompaniesTest do
  use Cympho.DataCase

  alias Cympho.{AgentInstructionStudio, Agents, Companies}
  alias Cympho.Companies.{Company, CompanyInvite, JoinRequest}
  alias Cympho.Goals.Goal
  alias Cympho.Projects
  alias Cympho.Secrets

  describe "companies" do
    test "create_company/1 with valid data creates a company" do
      attrs = %{name: "Test Corp", slug: "test-corp"}
      assert {:ok, %Company{} = company} = Companies.create_company(attrs)
      assert company.name == "Test Corp"
      assert company.slug == "test-corp"
    end

    test "create_company/1 with logo_url" do
      attrs = %{name: "Logo Corp", slug: "logo-corp", logo_url: "https://example.com/logo.png"}
      assert {:ok, %Company{} = company} = Companies.create_company(attrs)
      assert company.logo_url == "https://example.com/logo.png"
    end

    test "create_company/1 with invalid slug returns error" do
      attrs = %{name: "Bad", slug: "INVALID SLUG!"}
      assert {:error, changeset} = Companies.create_company(attrs)

      assert "must contain only lowercase letters, numbers, and hyphens" in errors_on(changeset).slug
    end

    test "create_company/1 with duplicate slug returns error" do
      Companies.create_company(%{name: "First", slug: "dup-slug"})
      assert {:error, changeset} = Companies.create_company(%{name: "Second", slug: "dup-slug"})
      assert "has already been taken" in errors_on(changeset).slug
    end

    test "get_company_by_slug/1 returns company by slug" do
      {:ok, company} = Companies.create_company(%{name: "Slug Corp", slug: "slug-corp"})
      assert Companies.get_company_by_slug("slug-corp").id == company.id
    end
  end

  describe "invites" do
    setup do
      {:ok, company} = Companies.create_company(%{name: "Invite Corp", slug: "invite-corp"})

      {:ok, user} =
        Cympho.Authentication.register_user(%{
          email: "inviter@test.com",
          name: "Inviter",
          password: "password123"
        })

      {:ok, company: company, user: user}
    end

    test "create_invite/1 creates a pending invite", %{company: company, user: user} do
      attrs = %{
        "company_id" => company.id,
        "inviter_id" => user.id,
        "email" => "new@test.com",
        "role" => "member"
      }

      assert {:ok, %CompanyInvite{} = invite} = Companies.create_invite(attrs)
      assert invite.token != nil
      assert invite.status == "pending"
      assert invite.expires_at != nil
    end

    test "accept_invite/2 creates membership", %{company: company, user: user} do
      attrs = %{
        "company_id" => company.id,
        "inviter_id" => user.id,
        "email" => "new@test.com",
        "role" => "member"
      }

      {:ok, invite} = Companies.create_invite(attrs)

      {:ok, new_user} =
        Cympho.Authentication.register_user(%{
          email: "new@test.com",
          name: "New",
          password: "password123"
        })

      assert {:ok, _} = Companies.accept_invite(invite.token, new_user.id)
      assert Companies.has_access?(new_user.id, company.id)
    end

    test "accept_invite/2 rejects a user whose email does not match the invite",
         %{company: company, user: user} do
      attrs = %{
        "company_id" => company.id,
        "inviter_id" => user.id,
        "email" => "intended@test.com",
        "role" => "member"
      }

      {:ok, invite} = Companies.create_invite(attrs)

      {:ok, attacker} =
        Cympho.Authentication.register_user(%{
          email: "attacker@test.com",
          name: "Attacker",
          password: "password123"
        })

      assert {:error, :email_mismatch} = Companies.accept_invite(invite.token, attacker.id)
      refute Companies.has_access?(attacker.id, company.id)
    end

    test "accept_invite/2 with expired token returns error", %{company: company, user: user} do
      expired = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:second)

      invite = %CompanyInvite{
        company_id: company.id,
        inviter_id: user.id,
        email: "expired@test.com",
        token: "expired-token",
        status: "pending",
        expires_at: expired
      }

      {:ok, _invite} = Repo.insert(invite)

      assert {:error, :expired} = Companies.accept_invite("expired-token", user.id)
    end
  end

  describe "join requests" do
    setup do
      {:ok, company} = Companies.create_company(%{name: "Join Corp", slug: "join-corp"})

      {:ok, user} =
        Cympho.Authentication.register_user(%{
          email: "joiner@test.com",
          name: "Joiner",
          password: "password123"
        })

      {:ok, company: company, user: user}
    end

    test "create_join_request/1 creates pending request", %{company: company, user: user} do
      assert {:ok, %JoinRequest{} = req} =
               Companies.create_join_request(%{
                 company_id: company.id,
                 user_id: user.id,
                 message: "Please let me in"
               })

      assert req.status == "pending"
    end

    test "approve_join_request/2 creates membership", %{company: company, user: user} do
      {:ok, req} = Companies.create_join_request(%{company_id: company.id, user_id: user.id})
      assert {:ok, _} = Companies.approve_join_request(req, user.id)
      assert Companies.has_access?(user.id, company.id)
    end

    test "reject_join_request/2 keeps user out", %{company: company, user: user} do
      {:ok, req} = Companies.create_join_request(%{company_id: company.id, user_id: user.id})
      assert {:ok, _} = Companies.reject_join_request(req, user.id)
      refute Companies.has_access?(user.id, company.id)
    end
  end

  describe "export/import" do
    test "export_company/1 scrubs secret fields" do
      {:ok, company} = Companies.create_company(%{name: "Export Corp", slug: "export-corp"})

      {:ok, _project} =
        Projects.create_project(%{
          name: "Sensitive GitHub",
          prefix: "SGH",
          company_id: company.id,
          github_webhook_secret: "github-webhook-secret"
        })

      data = Companies.export_company(company.id)

      assert data.company.logo_url == nil
      refute data.company[:password_hash]

      [project] = data.projects
      assert project.github_webhook_secret == "***REDACTED***"
      refute inspect(data) =~ "github-webhook-secret"
    end

    test "export_company/1 recursively scrubs legacy nested agent credentials" do
      {:ok, company} =
        Companies.create_company(%{name: "Nested Secret Corp", slug: "nested-secret"})

      {:ok, _agent} =
        Agents.create_agent(%{
          name: "Legacy Credential Agent",
          role: :engineer,
          status: :idle,
          adapter: :codex,
          company_id: company.id,
          config: %{
            "api_key" => "legacy-plain-api-key",
            "provider" => %{
              "access_token" => "legacy-access-token",
              "client_secret" => "legacy-client-secret",
              "label" => "safe-provider-label"
            },
            "credentials" => [
              %{"refresh_token" => "legacy-refresh-token"},
              %{"label" => "safe-list-label"}
            ]
          }
        })

      data = Companies.export_company(company.id)
      [agent] = data.agents

      assert agent.config["api_key"] == "***REDACTED***"
      assert agent.config["provider"]["access_token"] == "***REDACTED***"
      assert agent.config["provider"]["client_secret"] == "***REDACTED***"
      assert agent.config["provider"]["label"] == "safe-provider-label"
      assert agent.config["credentials"] == "***REDACTED***"

      exported = inspect(data)
      refute exported =~ "legacy-plain-api-key"
      refute exported =~ "legacy-access-token"
      refute exported =~ "legacy-client-secret"
      refute exported =~ "legacy-refresh-token"

      json_data = data |> Jason.encode!() |> Jason.decode!()

      assert {:ok, result} = Companies.import_company(json_data)
      [imported_agent] = Agents.list_agents_by_company(result.company.id)

      refute Map.has_key?(imported_agent.config, "api_key")
      refute Map.has_key?(imported_agent.config["provider"], "access_token")
      refute Map.has_key?(imported_agent.config["provider"], "client_secret")
      assert imported_agent.config["provider"]["label"] == "safe-provider-label"
      refute Map.has_key?(imported_agent.config, "credentials")
    end

    test "export/import redacts arbitrary HTTP authorization and process environments" do
      {:ok, company} =
        Companies.create_company(%{name: "Adapter Config Secret Corp", slug: "adapter-secrets"})

      {:ok, _http_agent} =
        Agents.create_agent(%{
          name: "Sensitive HTTP Agent",
          role: :engineer,
          status: :idle,
          adapter: :http,
          company_id: company.id,
          config: %{
            "url" => "https://example.test/hook",
            "headers" => %{
              "Authorization" => "Bearer leaked-http-token",
              "Cookie" => "session=leaked-cookie",
              "X-API-Key" => "leaked-header-key",
              "Accept" => "application/json"
            },
            "Authorization" => "Bearer leaked-top-level-token",
            "x-api-key" => "leaked-top-level-key",
            "DATABASE-URL" => "postgres://leaked-database-url",
            "client-credential" => "leaked-client-credential",
            "label" => "safe-http-label",
            "masked_note" => "***REDACTED***",
            "fallbacks" => ["safe-fallback", "***REDACTED***"]
          }
        })

      {:ok, _process_agent} =
        Agents.create_agent(%{
          name: "Sensitive Process Agent",
          role: :engineer,
          status: :idle,
          adapter: :process,
          company_id: company.id,
          config: %{
            "command" => "safe-command",
            "env" => %{
              "DATABASE_URL" => "postgres://leaked-process-database",
              "SAFE_MODE" => "true"
            },
            "label" => "safe-process-label"
          }
        })

      data = Companies.export_company(company.id)
      http_export = Enum.find(data.agents, &(&1.name == "Sensitive HTTP Agent"))
      process_export = Enum.find(data.agents, &(&1.name == "Sensitive Process Agent"))

      assert http_export.config["headers"] == "***REDACTED***"
      assert http_export.config["Authorization"] == "***REDACTED***"
      assert http_export.config["x-api-key"] == "***REDACTED***"
      assert http_export.config["DATABASE-URL"] == "***REDACTED***"
      assert http_export.config["client-credential"] == "***REDACTED***"
      assert http_export.config["label"] == "safe-http-label"
      assert process_export.config["env"] == "***REDACTED***"
      assert process_export.config["command"] == "safe-command"
      assert process_export.config["label"] == "safe-process-label"

      exported = inspect(data)
      refute exported =~ "leaked-http-token"
      refute exported =~ "leaked-cookie"
      refute exported =~ "leaked-header-key"
      refute exported =~ "leaked-top-level-token"
      refute exported =~ "leaked-top-level-key"
      refute exported =~ "leaked-database-url"
      refute exported =~ "leaked-client-credential"
      refute exported =~ "leaked-process-database"

      json_data = data |> Jason.encode!() |> Jason.decode!()
      assert {:ok, result} = Companies.import_company(json_data)

      imported_agents = Agents.list_agents_by_company(result.company.id)
      imported_http = Enum.find(imported_agents, &(&1.name == "Sensitive HTTP Agent"))
      imported_process = Enum.find(imported_agents, &(&1.name == "Sensitive Process Agent"))

      refute Map.has_key?(imported_http.config, "headers")
      refute Map.has_key?(imported_http.config, "Authorization")
      refute Map.has_key?(imported_http.config, "x-api-key")
      refute Map.has_key?(imported_http.config, "DATABASE-URL")
      refute Map.has_key?(imported_http.config, "client-credential")
      refute Map.has_key?(imported_http.config, "masked_note")
      assert imported_http.config["url"] == "https://example.test/hook"
      assert imported_http.config["label"] == "safe-http-label"
      assert imported_http.config["fallbacks"] == ["safe-fallback"]

      refute Map.has_key?(imported_process.config, "env")
      assert imported_process.config["command"] == "safe-command"
      assert imported_process.config["label"] == "safe-process-label"
    end

    test "export_company/1 includes a non-sensitive secret restore manifest" do
      {:ok, company} = Companies.create_company(%{name: "Manifest Corp", slug: "manifest-corp"})

      {:ok, _secret} =
        Secrets.create_secret(%{
          company_id: company.id,
          scope: "company",
          key: "DASHSCOPE_API_KEY",
          value: "super-secret-provider-key",
          description: "Qwen runtime credential"
        })

      data = Companies.export_company(company.id)

      assert [
               %{
                 key: "DASHSCOPE_API_KEY",
                 scope: "company",
                 scope_id: nil,
                 description: "Qwen runtime credential",
                 version: 1
               } = manifest_entry
             ] = data.secret_manifest

      assert manifest_entry.inserted_at
      assert manifest_entry.updated_at
      refute Map.has_key?(manifest_entry, :encrypted_value)
      refute inspect(data) =~ "super-secret-provider-key"
    end

    test "import_company/1 creates new company from exported data" do
      {:ok, company} = Companies.create_company(%{name: "Source Corp", slug: "source-corp"})
      data = Companies.export_company(company.id)

      assert {:ok, result} = Companies.import_company(data)
      assert result.company.name == "Source Corp"
      assert result.company.slug =~ "source-corp"
      assert result.company.id != company.id
    end

    test "import_company/1 returns remapped secrets that need restoration" do
      {:ok, company} = Companies.create_company(%{name: "Secret Source", slug: "secret-source"})

      {:ok, project} =
        Projects.create_project(%{
          name: "Secret Project",
          prefix: "SPR",
          company_id: company.id
        })

      {:ok, _secret} =
        Secrets.create_secret(%{
          company_id: company.id,
          scope: "project",
          scope_id: project.id,
          key: "PROJECT_TOKEN",
          value: "do-not-export-this-token",
          description: "Project deploy token"
        })

      data = Companies.export_company(company.id)
      json_data = data |> Jason.encode!() |> Jason.decode!()

      assert {:ok, result} = Companies.import_company(json_data)
      new_project_id = Map.fetch!(result.id_maps.projects, project.id)

      assert [
               %{
                 key: "PROJECT_TOKEN",
                 scope: "project",
                 original_scope_id: old_project_id,
                 scope_id: ^new_project_id,
                 description: "Project deploy token",
                 restore_status: "requires_value"
               }
             ] = result.secrets_to_restore

      assert old_project_id == project.id
      assert Secrets.list_secrets(result.company.id) == []
      refute inspect(result) =~ "do-not-export-this-token"
    end

    test "import_company/1 handles slug collision with suffix strategy" do
      {:ok, _existing} = Companies.create_company(%{name: "Existing", slug: "collide-corp"})
      {:ok, company} = Companies.create_company(%{name: "Source", slug: "source-corp"})
      data = Companies.export_company(company.id)
      # Simulate slug collision by overwriting the exported slug
      data = put_in(data, [:company, :slug], "collide-corp")

      assert {:ok, result} = Companies.import_company(data, slug_strategy: :suffix)
      assert result.company.slug != "collide-corp"
      assert String.contains?(result.company.slug, "collide-corp")
    end
  end

  describe "create_autonomous_company/1" do
    test "lists autonomous company blueprints for onboarding and CLI" do
      blueprints = Companies.autonomous_company_blueprints()
      keys = Enum.map(blueprints, & &1.key)

      expected_keys = ~w(
        software
        go_to_market
        product_discovery
        support_ops
        content_studio
        sales_pipeline
        research_lab
        qa_release
        agency_delivery
        community_growth
        security_compliance
        data_insights
        finance_ops
        devtools_platform
        incident_response
        partnerships
        training_academy
      )

      assert length(blueprints) >= length(expected_keys)
      assert Enum.all?(expected_keys, &(&1 in keys))

      assert {:ok, blueprint} = Companies.autonomous_company_blueprint("go_to_market")
      assert blueprint.default_prefix == "GTM"
      assert blueprint.seed_issue_count == 5
      assert blueprint.role_summary =~ "Sales"
      assert blueprint.default_agent_count > 10
      assert blueprint.extra_agent_count == 5
      assert blueprint.capability_count > 10
      assert "prospecting" in blueprint.capability_tags
      assert "sales_development" in blueprint.roles
      assert "Build the first outbound prospect list" in blueprint.seed_issue_titles
      assert is_list(blueprint.launch_manifest["agent_roster"])
      assert is_list(blueprint.launch_manifest["seed_work"])

      assert {:ok, manifest} =
               Companies.autonomous_company_blueprint_manifest("go_to_market",
                 engineer_count: "3"
               )

      assert manifest["engineer_count"] == 3
      assert manifest["agent_count"] == blueprint.default_agent_count + 1
      assert manifest["seed_issue_count"] == blueprint.seed_issue_count
      assert Enum.any?(manifest["agent_roster"], &(&1["ref"] == "engineer_3"))
    end

    test "every listed blueprint can bootstrap a live company" do
      blueprints = Companies.autonomous_company_blueprints()

      assert length(blueprints) >= 17

      for blueprint <- blueprints do
        assert {:ok, result} =
                 Companies.create_autonomous_company(%{
                   name: "Blueprint #{blueprint.key} Smoke",
                   blueprint: blueprint.key,
                   engineer_count: 1
                 })

        assert result.blueprint.key == blueprint.key
        assert result.company.governance_config["company_blueprint"] == blueprint.key
        assert result.project.name
        assert result.goal.goal_type == :mission
        assert length(result.seed_issues) == blueprint.seed_issue_count
        assert Enum.all?(result.seed_issues, &(&1.assignee_id && &1.assigned_role))

        manifest = result.company.governance_config["company_blueprint_manifest"]
        assert manifest["blueprint_key"] == blueprint.key
        assert manifest["agent_count"] == length(result.agents)
        assert manifest["seed_issue_count"] == blueprint.seed_issue_count
        assert length(manifest["agent_roster"]) == length(result.agents)
        assert length(manifest["seed_work"]) == length(result.seed_issues)
      end
    end

    test "normalizes API and CLI engineer counts before building blueprint manifests" do
      assert {:ok, result} =
               Companies.create_autonomous_company(%{
                 name: "String Engineer Count Co",
                 blueprint: "software",
                 engineer_count: "20"
               })

      manifest = result.company.governance_config["company_blueprint_manifest"]

      assert manifest["engineer_count"] == 8
      assert manifest["agent_count"] == length(result.agents)
      assert Enum.any?(manifest["agent_roster"], &(&1["ref"] == "engineer_8"))
      refute Enum.any?(manifest["agent_roster"], &(&1["ref"] == "engineer_9"))
    end

    test "creates company with agents, goal, project, and seed issues" do
      assert {:ok, result} =
               Companies.create_autonomous_company(%{
                 name: "Bootstrap Test Co",
                 goal_title: "Build something great",
                 engineer_count: 2
               })

      assert %Company{name: "Bootstrap Test Co"} = result.company
      assert result.blueprint.key == "software"
      assert result.project.name == "Company OS"
      assert %Goal{title: "Build something great", goal_type: :mission} = result.goal
      assert length(result.agents) == 6

      [ceo, cto, eng1, eng2, product_lead, design_lead] = result.agents
      assert ceo.role == :ceo
      assert ceo.instructions =~ "Product"
      assert ceo.instructions =~ "Design"
      assert ceo.instructions =~ "## Owner-readable memory"
      assert ceo.instructions =~ "## CEO delegation"
      assert ceo.instructions =~ "## CEO owner signoff loop"
      assert ceo.instructions =~ "Coordination packet"
      assert ceo.instructions =~ "target role/agent, dependency order, estimated minutes"
      assert ceo.instructions =~ "Business status"
      assert cto.role == :cto
      assert cto.parent_id == ceo.id
      assert cto.instructions =~ "## CTO split and review"
      assert cto.instructions =~ "Coordination packet"
      assert cto.instructions =~ "first file/artifact/test area to inspect"
      assert cto.instructions =~ "[review] Verdict:"
      assert eng1.role == :engineer
      assert eng1.parent_id == cto.id
      assert eng1.instructions =~ "## Delivery evidence"
      assert eng1.instructions =~ "[delivery] What happened:"
      assert eng2.role == :engineer
      assert eng2.parent_id == cto.id
      assert product_lead.role == :product_manager
      assert product_lead.parent_id == ceo.id
      assert design_lead.role == :designer
      assert design_lead.parent_id == ceo.id

      assert length(result.seed_issues) == 5
      assert Enum.all?(result.seed_issues, &(&1.goal_id == result.goal.id))
      assert Enum.all?(result.seed_issues, &(&1.origin_type == "onboarding"))

      for agent <- [ceo, cto, eng1, product_lead, design_lead] do
        studio = AgentInstructionStudio.analyze(agent)

        assert studio.status == :good
        assert studio.score >= 90
      end
    end

    test "creates go-to-market blueprint with specialized agents and seed work" do
      assert {:ok, result} =
               Companies.create_autonomous_company(%{
                 name: "Growth Blueprint Co",
                 blueprint: "go_to_market",
                 engineer_count: 1
               })

      assert result.blueprint.key == "go_to_market"
      assert result.company.governance_config["company_blueprint"] == "go_to_market"
      assert result.company.description =~ "growth company"
      assert result.project.name == "Growth OS"

      assert %Goal{
               title: "Launch a repeatable go-to-market motion for the offer",
               goal_type: :mission
             } = result.goal

      roles = Enum.map(result.agents, & &1.role)

      assert :ceo in roles
      assert :cto in roles
      assert :engineer in roles
      assert :product_manager in roles
      assert :designer in roles
      assert :researcher in roles
      assert :marketer in roles
      assert :content_strategist in roles
      assert :sales_development in roles
      assert :customer_support in roles

      assert length(result.agents) == 10
      assert length(result.seed_issues) == 5

      assert Enum.any?(
               result.seed_issues,
               &(&1.title == "Build the first outbound prospect list" and
                   &1.assigned_role == "sales_development")
             )

      assert Enum.any?(
               result.seed_issues,
               &(&1.title == "Create the first support knowledge base skeleton" and
                   &1.assigned_role == "customer_support")
             )
    end

    test "creates QA and release blueprint with specialized agents and seed work" do
      assert {:ok, result} =
               Companies.create_autonomous_company(%{
                 name: "Release Blueprint Co",
                 blueprint: "qa_release",
                 engineer_count: 1
               })

      assert result.blueprint.key == "qa_release"
      assert result.company.governance_config["company_blueprint"] == "qa_release"
      assert result.project.name == "Release OS"

      assert %Goal{
               title: "Ship changes safely with clear QA, release, and rollback evidence",
               goal_type: :mission
             } = result.goal

      roles = Enum.map(result.agents, & &1.role)

      assert :qa_engineer in roles
      assert :release_engineer in roles
      assert length(result.agents) == 7
      assert length(result.seed_issues) == 5

      assert Enum.any?(
               result.seed_issues,
               &(&1.assigned_role == "qa_engineer" and &1.assignee_id)
             )

      assert Enum.any?(
               result.seed_issues,
               &(&1.assigned_role == "release_engineer" and &1.assignee_id)
             )
    end

    test "keeps duplicate blueprint project prefixes valid" do
      assert {:ok, first} =
               Companies.create_autonomous_company(%{
                 name: "First Growth Prefix Co",
                 blueprint: "go_to_market",
                 engineer_count: 1
               })

      assert {:ok, second} =
               Companies.create_autonomous_company(%{
                 name: "Second Growth Prefix Co",
                 blueprint: "go_to_market",
                 engineer_count: 1
               })

      assert first.project.prefix == "GTM"
      assert second.project.prefix != first.project.prefix
      assert second.project.prefix =~ ~r/^[A-Z]+$/
      assert String.length(second.project.prefix) <= 10
    end

    test "works with zero engineers" do
      assert {:ok, result} =
               Companies.create_autonomous_company(%{
                 name: "No Eng Co",
                 engineer_count: 0
               })

      assert length(result.agents) == 4
      [ceo, cto, product_lead, design_lead] = result.agents
      assert ceo.role == :ceo
      assert cto.role == :cto
      assert product_lead.role == :product_manager
      assert design_lead.role == :designer

      eng_issue =
        Enum.find(result.seed_issues, &(&1.assigned_role == "cto" and &1.issue_number == 4))

      assert eng_issue.assignee_id == cto.id
    end

    test "creates goal with mission type" do
      assert {:ok, result} = Companies.create_autonomous_company(%{name: "Mission Co"})
      assert result.goal.goal_type == :mission
    end

    test "handles duplicate company names with unique slugs" do
      Companies.create_company(%{name: "Collision Co", slug: "collision-co"})

      assert {:ok, _result} =
               Companies.create_autonomous_company(%{name: "Collision Co", engineer_count: 3})
    end
  end
end
