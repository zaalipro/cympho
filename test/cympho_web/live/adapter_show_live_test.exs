defmodule CymphoWeb.AdapterShowLiveTest do
  use CymphoWeb.LiveCase, async: true

  import Phoenix.LiveViewTest

  alias Cympho.{Agents, Companies, Secrets}

  describe "AdapterLive.Show" do
    setup %{conn: conn, current_company: company} = context do
      unless context[:regular_member] do
        user_id = Plug.Conn.get_session(conn, :user_id)
        membership = Companies.get_membership(user_id, company.id)
        assert {:ok, _membership} = Companies.update_membership(membership, %{role: "admin"})
      end

      :ok
    end

    test "mounts and renders a registered adapter", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/settings/adapters/claude_code")

      assert html =~ "Runtime adapter"
      assert html =~ "All adapters"
    end

    test "associates adapter labels and explains encrypted API-key storage", %{conn: conn} do
      {:ok, view, html} = live(conn, "/settings/adapters/openai_chat")

      assert has_element?(view, "label[for='adapter-config-endpoint']")
      assert has_element?(view, "#adapter-config-endpoint[required]")
      assert has_element?(view, "label[for='adapter-config-api_key']")
      assert has_element?(view, "#adapter-config-api_key[required]")
      assert html =~ "encrypted company Secrets"
      assert html =~ "and are not copied into agent configs"
    end

    test "redirects back to the index for an unknown adapter key", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/settings/adapters"}}} =
               live(conn, "/settings/adapters/definitely_not_a_real_adapter_xyz")
    end

    # Regression: adapters whose config_schema has a map-typed `default:`
    # (:process, :http) used to crash mount — the map was rendered straight
    # into an <input> value attribute. Now encoded as JSON via input_value/1.
    test "mounts the process adapter (map-default config)", %{conn: conn} do
      {:ok, view, html} = live(conn, "/settings/adapters/process")

      assert html =~ "Runtime adapter"

      assert has_element?(
               view,
               ~s(input[name="config[prompt_stdin]"][type="checkbox"][value="true"][checked])
             )
    end

    test "saves company provider settings when no agents use the adapter yet", %{
      conn: conn,
      current_company: company
    } do
      {:ok, view, _html} = live(conn, "/settings/adapters/openai_chat")

      html =
        view
        |> form("form[phx-submit='save_config']", %{
          "config" => %{
            "endpoint" => "https://cli.llmotions.com/v1",
            "api_key" => "llmotions-from-settings",
            "model" => "gemini-3.7-flash"
          }
        })
        |> render_submit()

      refute html =~ "nothing was saved"
      refute html =~ "Validation failed"
      refute html =~ "could not be stored"

      assert {:ok, secret} =
               Secrets.get_secret_by_key(company.id, "LLMOTIONS_API_KEY", scope: "company")

      assert {:ok, "llmotions-from-settings"} = Secrets.get_secret_value(secret.id)

      assert {:ok, endpoint_secret} =
               Secrets.get_secret_by_key(company.id, "OPENAI_CHAT_ENDPOINT", scope: "company")

      assert {:ok, "https://cli.llmotions.com/v1"} = Secrets.get_secret_value(endpoint_secret.id)
    end

    @tag regular_member: true
    test "regular members cannot access adapter controls or change company credentials", %{
      conn: conn,
      current_company: company
    } do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Member-protected Chat Agent",
          role: :engineer,
          status: :idle,
          adapter: :openai_chat,
          company_id: company.id,
          config: %{
            "endpoint" => "https://old.example/v1",
            "model" => "old-model"
          }
        })

      {:ok, original_secret} =
        Secrets.create_secret(%{
          company_id: company.id,
          scope: "company",
          key: "OPENAI_API_KEY",
          value: "original-encrypted-key"
        })

      {:ok, view, html} = live(conn, "/settings/adapters/openai_chat")

      assert html =~ ~s(data-testid="adapter-config-read-only")
      refute has_element?(view, "form[phx-submit='save_config']")
      refute has_element?(view, "button[phx-click='test_health']")
      refute has_element?(view, "button[phx-click='send_test_heartbeat']")

      assert render_click(view, "test_health", %{}) =~
               "Only company owners, admins, and board members can change adapter settings."

      assert render_click(view, "send_test_heartbeat", %{}) =~
               "Only company owners, admins, and board members can change adapter settings."

      assert render_change(view, "validate_config", %{
               "config" => %{"endpoint" => "https://new.example/v1", "model" => "new-model"}
             }) =~ "Only company owners, admins, and board members can change adapter settings."

      html =
        render_submit(view, "save_config", %{
          "config" => %{
            "endpoint" => "https://new.example/v1",
            "api_key" => "unauthorized-replacement-key",
            "model" => "new-model"
          }
        })

      assert html =~ "Only company owners, admins, and board members"

      {:ok, reloaded} = Agents.get_agent(agent.id)
      assert reloaded.config["endpoint"] == "https://old.example/v1"
      assert reloaded.config["model"] == "old-model"

      assert {:ok, active_secret} =
               Secrets.get_secret_by_key(company.id, "OPENAI_API_KEY", scope: "company")

      assert active_secret.id == original_secret.id
      assert active_secret.version == 1
      assert {:ok, "original-encrypted-key"} = Secrets.get_secret_value(active_secret.id)
    end

    test "shows connect form in Simple mode so owners can add an endpoint", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings/adapters/openai_chat")

      assert has_element?(view, "button[phx-click='test_health']")
      assert has_element?(view, "button[phx-click='send_test_heartbeat']")

      assert has_element?(
               view,
               "[data-testid='adapter-config-card'] form[phx-submit='save_config']"
             )

      assert has_element?(view, "[data-testid='adapter-config-card']", "Connect this provider")
      assert has_element?(view, ".ui-advanced-only", "Module")
    end

    test "new API keys are stored as encrypted company secrets instead of agent config", %{
      conn: conn,
      current_company: company
    } do
      {:ok, first} =
        Agents.create_agent(%{
          name: "First Secret-backed Chat Agent",
          role: :ceo,
          status: :idle,
          adapter: :openai_chat,
          company_id: company.id,
          config: %{
            "endpoint" => "https://old.example/v1",
            "api_key" => "legacy-first-key",
            "model" => "old-model"
          }
        })

      {:ok, second} =
        Agents.create_agent(%{
          name: "Second Secret-backed Chat Agent",
          role: :cto,
          status: :idle,
          adapter: :openai_chat,
          company_id: company.id,
          config: %{"endpoint" => "https://old.example/v1", "model" => "old-model"}
        })

      {:ok, view, _html} = live(conn, "/settings/adapters/openai_chat")

      view
      |> form("form[phx-submit='save_config']", %{
        "config" => %{
          "endpoint" => "https://cli.llmotions.com/v1",
          "api_key" => "new-encrypted-key",
          "model" => "gpt-5.6-terra"
        }
      })
      |> render_change()

      html =
        view
        |> form("form[phx-submit='save_config']", %{
          "config" => %{
            "endpoint" => "https://cli.llmotions.com/v1",
            "api_key" => "",
            "model" => "gpt-5.6-terra"
          }
        })
        |> render_submit()

      assert html =~ "Configured — leave blank to keep"
      refute html =~ "new-encrypted-key"
      refute html =~ "legacy-first-key"

      {:ok, first} = Agents.get_agent(first.id)
      {:ok, second} = Agents.get_agent(second.id)

      refute Map.has_key?(first.config, "api_key")
      refute Map.has_key?(second.config, "api_key")
      assert first.config["endpoint"] == "https://cli.llmotions.com/v1"
      assert second.config["endpoint"] == "https://cli.llmotions.com/v1"

      assert {:ok, secret} =
               Secrets.get_secret_by_key(company.id, "LLMOTIONS_API_KEY", scope: "company")

      refute secret.encrypted_value == "new-encrypted-key"
      assert {:ok, "new-encrypted-key"} = Secrets.get_secret_value(secret.id)
    end

    test "commits a new encrypted key and every agent configuration together", %{
      conn: conn,
      current_company: company
    } do
      {:ok, first} =
        Agents.create_agent(%{
          name: "First Atomic Chat Agent",
          role: :ceo,
          status: :idle,
          adapter: :openai_chat,
          company_id: company.id,
          config: %{"endpoint" => "https://old.example/v1", "model" => "old-model"}
        })

      {:ok, second} =
        Agents.create_agent(%{
          name: "Second Atomic Chat Agent",
          role: :cto,
          status: :idle,
          adapter: :openai_chat,
          company_id: company.id,
          config: %{"endpoint" => "https://old.example/v1", "model" => "old-model"}
        })

      {:ok, view, _html} = live(conn, "/settings/adapters/openai_chat")

      view
      |> form("form[phx-submit='save_config']", %{
        "config" => %{
          "endpoint" => "https://cli.llmotions.com/v1",
          "api_key" => "atomic-encrypted-key",
          "model" => "gpt-5.6-terra"
        }
      })
      |> render_submit()

      for agent <- [first, second] do
        {:ok, reloaded} = Agents.get_agent(agent.id)
        assert reloaded.config["endpoint"] == "https://cli.llmotions.com/v1"
        assert reloaded.config["model"] == "gpt-5.6-terra"
        refute Map.has_key?(reloaded.config, "api_key")
      end

      assert {:ok, secret} =
               Secrets.get_secret_by_key(company.id, "LLMOTIONS_API_KEY", scope: "company")

      assert {:ok, "atomic-encrypted-key"} = Secrets.get_secret_value(secret.id)
    end

    test "rolls back an API key rotation when a bulk agent configuration update fails", %{
      conn: conn,
      current_company: company
    } do
      {:ok, first} =
        Agents.create_agent(%{
          name: "First Rollback Chat Agent",
          role: :ceo,
          status: :idle,
          adapter: :openai_chat,
          company_id: company.id,
          config: %{"endpoint" => "https://old.example/v1", "model" => "old-model"}
        })

      {:ok, second} =
        Agents.create_agent(%{
          name: "Deleted Rollback Chat Agent",
          role: :cto,
          status: :idle,
          adapter: :openai_chat,
          company_id: company.id,
          config: %{"endpoint" => "https://old.example/v1", "model" => "old-model"}
        })

      {:ok, original_secret} =
        Secrets.create_secret(%{
          company_id: company.id,
          scope: "company",
          key: "LLMOTIONS_API_KEY",
          value: "old-atomic-key"
        })

      {:ok, view, _html} = live(conn, "/settings/adapters/openai_chat")
      assert {:ok, _deleted} = Agents.delete_agent(second)

      html =
        view
        |> form("form[phx-submit='save_config']", %{
          "config" => %{
            "endpoint" => "https://cli.llmotions.com/v1",
            "api_key" => "replacement-atomic-key",
            "model" => "gpt-5.6-terra"
          }
        })
        |> render_submit()

      assert html =~ "Configuration was not saved"
      assert html =~ "no changes were applied"

      {:ok, reloaded_first} = Agents.get_agent(first.id)
      assert reloaded_first.config == first.config

      assert {:ok, active_secret} =
               Secrets.get_secret_by_key(company.id, "LLMOTIONS_API_KEY", scope: "company")

      assert active_secret.id == original_secret.id
      assert active_secret.version == 1
      assert active_secret.is_active
      assert {:ok, "old-atomic-key"} = Secrets.get_secret_value(active_secret.id)
      assert Secrets.list_secret_versions(original_secret.id) == [original_secret]
    end

    test "blank masked encrypted credentials remain unchanged", %{
      conn: conn,
      current_company: company
    } do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Encrypted Masked Chat Agent",
          role: :ceo,
          status: :idle,
          adapter: :openai_chat,
          company_id: company.id,
          config: %{
            "endpoint" => "https://cli.llmotions.com/v1",
            "model" => "gpt-5.6-terra"
          }
        })

      {:ok, original_secret} =
        Secrets.create_secret(%{
          company_id: company.id,
          scope: "company",
          key: "LLMOTIONS_API_KEY",
          value: "keep-encrypted-key"
        })

      {:ok, view, html} = live(conn, "/settings/adapters/openai_chat")

      assert html =~ "Configured — leave blank to keep"
      refute has_element?(view, "#adapter-config-api_key[required]")

      view
      |> form("form[phx-submit='save_config']", %{
        "config" => %{
          "endpoint" => "https://cli.llmotions.com/v1",
          "api_key" => "",
          "model" => "gpt-5.6-terra"
        }
      })
      |> render_submit()

      {:ok, reloaded} = Agents.get_agent(agent.id)
      refute Map.has_key?(reloaded.config, "api_key")

      assert {:ok, active_secret} =
               Secrets.get_secret_by_key(company.id, "LLMOTIONS_API_KEY", scope: "company")

      assert active_secret.id == original_secret.id
      assert active_secret.version == 1
      assert {:ok, "keep-encrypted-key"} = Secrets.get_secret_value(active_secret.id)
    end

    test "entering a replacement API key rotates the encrypted secret and removes legacy config",
         %{
           conn: conn,
           current_company: company
         } do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Rotating Chat Agent",
          role: :ceo,
          status: :idle,
          adapter: :openai_chat,
          company_id: company.id,
          config: %{
            "endpoint" => "https://cli.llmotions.com/v1",
            "api_key" => "legacy-agent-key",
            "model" => "gpt-5.6-terra"
          }
        })

      {:ok, original_secret} =
        Secrets.create_secret(%{
          company_id: company.id,
          scope: "company",
          key: "LLMOTIONS_API_KEY",
          value: "old-encrypted-key"
        })

      {:ok, view, _html} = live(conn, "/settings/adapters/openai_chat")

      view
      |> form("form[phx-submit='save_config']", %{
        "config" => %{
          "endpoint" => "https://cli.llmotions.com/v1",
          "api_key" => "replacement-encrypted-key",
          "model" => "gpt-5.6-terra"
        }
      })
      |> render_submit()

      {:ok, reloaded} = Agents.get_agent(agent.id)
      refute Map.has_key?(reloaded.config, "api_key")

      assert {:ok, active_secret} =
               Secrets.get_secret_by_key(company.id, "LLMOTIONS_API_KEY", scope: "company")

      assert active_secret.id != original_secret.id
      assert active_secret.version == 2
      assert {:ok, "replacement-encrypted-key"} = Secrets.get_secret_value(active_secret.id)
      assert {:ok, original_secret} = Secrets.get_secret(original_secret.id)
      refute original_secret.is_active
    end

    test "health checks use the saved adapter configuration", %{
      conn: conn,
      current_company: company
    } do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Configured Chat Agent",
          role: :ceo,
          status: :idle,
          adapter: :openai_chat,
          company_id: company.id,
          config: %{
            "endpoint" => "https://cli.llmotions.com/v1",
            "api_key" => "stored-test-key",
            "model" => "gpt-5.6-terra"
          }
        })

      {:ok, view, html} = live(conn, "/settings/adapters/openai_chat")

      assert html =~ "Healthy"
      refute html =~ "stored-test-key"
      assert has_element?(view, ~s(input[name="config[api_key]"][type="password"]))

      html = view |> element("button", "Validate config") |> render_click()
      assert html =~ "OpenAI-compatible chat configuration is present"
      refute html =~ "No chat completions endpoint configured"

      {:ok, reloaded} = Agents.get_agent(agent.id)
      assert reloaded.config["api_key"] == "stored-test-key"
    end

    test "blank masked credentials survive validation and save", %{
      conn: conn,
      current_company: company
    } do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Masked Chat Agent",
          role: :ceo,
          status: :idle,
          adapter: :openai_chat,
          company_id: company.id,
          config: %{
            "endpoint" => "https://old.example/v1",
            "api_key" => "keep-this-key",
            "model" => "old-model"
          }
        })

      {:ok, view, _html} = live(conn, "/settings/adapters/openai_chat")

      view
      |> form("form[phx-submit='save_config']", %{
        "config" => %{
          "endpoint" => "https://cli.llmotions.com/v1",
          "api_key" => "",
          "model" => "gpt-5.6-terra"
        }
      })
      |> render_submit()

      {:ok, reloaded} = Agents.get_agent(agent.id)
      assert reloaded.config["endpoint"] == "https://cli.llmotions.com/v1"
      assert reloaded.config["model"] == "gpt-5.6-terra"
      assert reloaded.config["api_key"] == "keep-this-key"
    end

    test "bulk save preserves agent-specific credentials and extension config", %{
      conn: conn,
      current_company: company
    } do
      {:ok, first} =
        Agents.create_agent(%{
          name: "First Bulk Chat Agent",
          role: :ceo,
          status: :idle,
          adapter: :openai_chat,
          company_id: company.id,
          config: %{
            "endpoint" => "https://old-one.example/v1",
            "api_key" => "first-agent-key",
            "model" => "old-one",
            "runtime_profile_id" => "profile-one",
            "provider" => "provider-one",
            "timeout" => 120_000
          }
        })

      {:ok, second} =
        Agents.create_agent(%{
          name: "Second Bulk Chat Agent",
          role: :cto,
          status: :idle,
          adapter: :openai_chat,
          company_id: company.id,
          config: %{
            "endpoint" => "https://old-two.example/v1",
            "api_key" => "second-agent-key",
            "model" => "old-two",
            "runtime_profile_id" => "profile-two",
            "provider" => "provider-two",
            "timeout" => 90_000
          }
        })

      {:ok, view, _html} = live(conn, "/settings/adapters/openai_chat")

      html =
        view
        |> form("form[phx-submit='save_config']", %{
          "config" => %{
            "endpoint" => "https://cli.llmotions.com/v1",
            "api_key" => "",
            "model" => "gpt-5.6-terra",
            "timeout_sec" => "45"
          }
        })
        |> render_submit()

      refute html =~ "first-agent-key"
      refute html =~ "second-agent-key"

      {:ok, first} = Agents.get_agent(first.id)
      {:ok, second} = Agents.get_agent(second.id)

      assert first.config["endpoint"] == "https://cli.llmotions.com/v1"
      assert second.config["endpoint"] == "https://cli.llmotions.com/v1"
      assert first.config["model"] == "gpt-5.6-terra"
      assert second.config["model"] == "gpt-5.6-terra"
      assert first.config["timeout_sec"] == 45
      assert second.config["timeout_sec"] == 45
      refute Map.has_key?(first.config, "timeout")
      refute Map.has_key?(second.config, "timeout")

      assert first.config["api_key"] == "first-agent-key"
      assert second.config["api_key"] == "second-agent-key"
      assert first.config["runtime_profile_id"] == "profile-one"
      assert second.config["runtime_profile_id"] == "profile-two"
      assert first.config["provider"] == "provider-one"
      assert second.config["provider"] == "provider-two"
    end

    test "browser number fields are parsed and only the human timeout unit is shown", %{
      conn: conn,
      current_company: company
    } do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Browser Config Agent",
          role: :engineer,
          status: :idle,
          adapter: :codex,
          company_id: company.id,
          config: %{"api_key" => "stored-test-key", "model" => "gpt-5.6-terra"}
        })

      {:ok, view, _html} = live(conn, "/settings/adapters/codex")

      assert has_element?(view, ~s(input[name="config[timeout_sec]"]))
      refute has_element?(view, ~s(input[name="config[timeout]"]))
      assert has_element?(view, ~s(input[name="config[max_tokens]"][type="number"]))
      refute has_element?(view, ~s(input[name="config[max_tokens]"][type="password"]))

      view
      |> form("form[phx-submit='save_config']", %{
        "config" => %{
          "api_key" => "",
          "model" => "gpt-5.6-terra",
          "temperature" => "0.7",
          "max_tokens" => "2000",
          "timeout_sec" => "300"
        }
      })
      |> render_submit()

      {:ok, reloaded} = Agents.get_agent(agent.id)
      assert reloaded.config["temperature"] == 0.7
      assert reloaded.config["max_tokens"] == 2_000
      assert reloaded.config["timeout_sec"] == 300
      assert reloaded.config["api_key"] == "stored-test-key"
    end
  end
end
