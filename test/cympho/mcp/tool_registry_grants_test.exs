defmodule Cympho.Mcp.ToolRegistryGrantsTest do
  use Cympho.DataCase, async: true

  defmodule DefaultToolWorker do
    use Cympho.Plugins.Worker
  end

  defmodule EchoToolWorker do
    use Cympho.Plugins.Worker

    def handle_request({:execute_tool, name, args, ctx}, _from, state) do
      {:reply, {:ok, %{executed: name, args: args, ctx: ctx}}, state}
    end
  end

  alias Cympho.Agents
  alias Cympho.Companies
  alias Cympho.Mcp.Server
  alias Cympho.Mcp.ToolGrants
  alias Cympho.Mcp.ToolRegistry
  alias Cympho.Plugins.HostServices
  alias Cympho.Skills

  setup do
    u = System.unique_integer([:positive])

    {:ok, company_a} =
      Companies.create_company(%{name: "RegA#{u}", slug: "reg-a-#{u}"})

    {:ok, company_b} =
      Companies.create_company(%{name: "RegB#{u}", slug: "reg-b-#{u}"})

    {:ok, agent_a} =
      Agents.create_agent(%{
        company_id: company_a.id,
        name: "Agent A",
        role: :engineer,
        status: :idle
      })

    {:ok, agent_a2} =
      Agents.create_agent(%{
        company_id: company_a.id,
        name: "Agent A2",
        role: :cto,
        status: :idle
      })

    {:ok, agent_b} =
      Agents.create_agent(%{
        company_id: company_b.id,
        name: "Agent B",
        role: :engineer,
        status: :idle
      })

    {:ok, plugin} =
      Skills.create_plugin(%{
        company_id: company_a.id,
        identifier: "tool-plugin-#{u}",
        version: "1.0.0",
        name: "Tool Plugin",
        manifest: %{"name" => "tool-plugin"},
        capabilities: ["expose:tools"],
        status: "active",
        enabled: true
      })

    %{
      company_a: company_a,
      company_b: company_b,
      agent_a: agent_a,
      agent_a2: agent_a2,
      agent_b: agent_b,
      plugin: plugin,
      u: u
    }
  end

  describe "ToolRegistry.register/2 and unregister/1" do
    test "registers company-scoped tools", %{company_a: company_a} do
      assert {:ok, tool} =
               ToolRegistry.register(company_a.id, %{
                 "name" => "weather_lookup",
                 "description" => "Looks up weather",
                 "inputSchema" => %{
                   "type" => "object",
                   "properties" => %{"city" => %{"type" => "string"}}
                 }
               })

      assert tool.company_id == company_a.id
      assert tool.name == "weather_lookup"
      assert tool.status == "active"
      assert tool.input_schema["type"] == "object"

      assert {:ok, ^tool} = ToolRegistry.get_active(company_a.id, "weather_lookup")
      assert [%{name: "weather_lookup"}] = ToolRegistry.list_registered(company_a.id)
    end

    test "rejects registration without company scope" do
      assert {:error, :invalid_company_scope} =
               ToolRegistry.register(nil, %{"name" => "x"})

      assert {:error, :invalid_company_scope} =
               ToolRegistry.register("", %{"name" => "x"})
    end

    test "rejects missing tool name", %{company_a: company_a} do
      assert {:error, :missing_tool_name} =
               ToolRegistry.register(company_a.id, %{"description" => "no name"})
    end

    test "unregister hides the tool immediately", %{
      company_a: company_a,
      agent_a: agent_a
    } do
      {:ok, tool} =
        ToolRegistry.register(company_a.id, %{
          "name" => "ephemeral_tool",
          "description" => "goes away"
        })

      {:ok, _grant} =
        ToolGrants.create_grant(%{
          company_id: company_a.id,
          tool_name: "ephemeral_tool",
          agent_id: agent_a.id,
          status: "allow"
        })

      assert ToolGrants.authorize_call(company_a.id, agent_a.id, "ephemeral_tool") == :allow
      assert Enum.any?(Server.tools_for(agent_a), &(&1.name == "ephemeral_tool"))

      assert {:ok, unregistered} = ToolRegistry.unregister(tool.id)
      assert unregistered.status == "unregistered"

      assert ToolRegistry.get_active(company_a.id, "ephemeral_tool") == {:error, :not_found}
      assert ToolGrants.authorize_call(company_a.id, agent_a.id, "ephemeral_tool") == :deny
      refute Enum.any?(Server.tools_for(agent_a), &(&1.name == "ephemeral_tool"))
    end

    test "tenant isolation: company B cannot see company A tools", %{
      company_a: company_a,
      company_b: company_b
    } do
      {:ok, _} =
        ToolRegistry.register(company_a.id, %{
          "name" => "secret_a_tool",
          "description" => "A only"
        })

      assert ToolRegistry.list_registered(company_b.id) == []
      assert ToolRegistry.get_active(company_b.id, "secret_a_tool") == {:error, :not_found}
    end
  end

  describe "ToolGrants.authorize_call/3 and revoke/2" do
    setup %{company_a: company_a} do
      {:ok, tool} =
        ToolRegistry.register(company_a.id, %{
          "name" => "ship_it",
          "description" => "Ships code"
        })

      %{tool: tool}
    end

    test "fail-closed without grant", %{company_a: company_a, agent_a: agent_a} do
      assert ToolGrants.authorize_call(company_a.id, agent_a.id, "ship_it") == :deny
      assert ToolGrants.authorize_call(nil, agent_a.id, "ship_it") == :deny
      assert ToolGrants.authorize_call(company_a.id, nil, "ship_it") == :deny
    end

    test "returns allow/deny/pending/revoked", %{
      company_a: company_a,
      agent_a: agent_a,
      tool: tool
    } do
      {:ok, grant} =
        ToolGrants.create_grant(%{
          company_id: company_a.id,
          tool_id: tool.id,
          tool_name: "ship_it",
          agent_id: agent_a.id,
          status: "pending"
        })

      assert ToolGrants.authorize_call(company_a.id, agent_a.id, "ship_it") == :pending

      {:ok, _} =
        ToolGrants.create_grant(%{
          company_id: company_a.id,
          tool_name: "ship_it",
          agent_id: agent_a.id,
          status: "allow"
        })

      assert ToolGrants.authorize_call(company_a.id, agent_a.id, "ship_it") == :allow

      {:ok, _} =
        ToolGrants.create_grant(%{
          company_id: company_a.id,
          tool_name: "ship_it",
          agent_id: agent_a.id,
          status: "deny"
        })

      assert ToolGrants.authorize_call(company_a.id, agent_a.id, "ship_it") == :deny

      # Latest agent-specific grant after revoke path
      {:ok, allow_again} =
        ToolGrants.create_grant(%{
          company_id: company_a.id,
          tool_name: "ship_it",
          agent_id: agent_a.id,
          status: "allow"
        })

      assert ToolGrants.authorize_call(company_a.id, agent_a.id, "ship_it") == :allow

      assert {:ok, revoked} = ToolGrants.revoke(allow_again.id, "owner revoked")
      assert revoked.status == "revoked"
      assert ToolGrants.authorize_call(company_a.id, agent_a.id, "ship_it") == :revoked

      # original pending grant still exists but latest is revoked
      assert grant.status == "pending"
    end

    test "company-wide grant applies when no agent-specific grant", %{
      company_a: company_a,
      agent_a: agent_a,
      agent_a2: agent_a2
    } do
      {:ok, _} =
        ToolGrants.create_grant(%{
          company_id: company_a.id,
          tool_name: "ship_it",
          agent_id: nil,
          status: "allow"
        })

      assert ToolGrants.authorize_call(company_a.id, agent_a.id, "ship_it") == :allow
      assert ToolGrants.authorize_call(company_a.id, agent_a2.id, "ship_it") == :allow
    end

    test "agent-specific grant does not leak to another agent", %{
      company_a: company_a,
      agent_a: agent_a,
      agent_a2: agent_a2
    } do
      {:ok, _} =
        ToolGrants.create_grant(%{
          company_id: company_a.id,
          tool_name: "ship_it",
          agent_id: agent_a.id,
          status: "allow"
        })

      assert ToolGrants.authorize_call(company_a.id, agent_a.id, "ship_it") == :allow
      assert ToolGrants.authorize_call(company_a.id, agent_a2.id, "ship_it") == :deny
    end

    test "tenant isolation: company B grant cannot authorize company A tool", %{
      company_a: company_a,
      company_b: company_b,
      agent_b: agent_b
    } do
      {:ok, _} =
        ToolGrants.create_grant(%{
          company_id: company_b.id,
          tool_name: "ship_it",
          agent_id: agent_b.id,
          status: "allow"
        })

      # Tool is not registered on B; grant cannot make a foreign tool callable.
      assert ToolGrants.authorize_call(company_b.id, agent_b.id, "ship_it") == :deny
      assert ToolGrants.authorize_call(company_a.id, agent_b.id, "ship_it") == :deny
    end
  end

  describe "MCP list/call gate" do
    setup %{company_a: company_a, agent_a: agent_a} do
      {:ok, tool} =
        ToolRegistry.register(company_a.id, %{
          "name" => "deploy_preview",
          "description" => "Deploy a preview",
          "inputSchema" => %{"type" => "object", "properties" => %{}}
        })

      %{tool: tool, agent: agent_a, company: company_a}
    end

    test "tools_for merges only granted dynamics", %{agent: agent, company: company} do
      names = Enum.map(Server.tools_for(agent), & &1.name)
      refute "deploy_preview" in names

      {:ok, grant} =
        ToolGrants.create_grant(%{
          company_id: company.id,
          tool_name: "deploy_preview",
          agent_id: agent.id,
          status: "allow"
        })

      names = Enum.map(Server.tools_for(agent), & &1.name)
      assert "deploy_preview" in names
      assert "list_issues" in names

      {:ok, _} = ToolGrants.revoke(grant.id, "hide now")
      names = Enum.map(Server.tools_for(agent), & &1.name)
      refute "deploy_preview" in names
    end

    test "call_tool allows only granted dynamics and reports decision", %{
      agent: agent,
      company: company
    } do
      result = Server.call_tool("deploy_preview", %{"env" => "staging"}, agent)
      assert result == %{error: "Tool not authorized", decision: "deny"}

      {:ok, grant} =
        ToolGrants.create_grant(%{
          company_id: company.id,
          tool_name: "deploy_preview",
          agent_id: agent.id,
          status: "pending"
        })

      result = Server.call_tool("deploy_preview", %{}, agent)
      assert result == %{error: "Tool not authorized", decision: "pending"}

      {:ok, _} =
        ToolGrants.create_grant(%{
          company_id: company.id,
          tool_name: "deploy_preview",
          agent_id: agent.id,
          status: "allow"
        })

      result = Server.call_tool("deploy_preview", %{"env" => "staging"}, agent)

      assert result == %{
               success: false,
               dynamic: true,
               tool: "deploy_preview",
               error: ":plugin_not_found"
             }

      {:ok, latest} =
        ToolGrants.create_grant(%{
          company_id: company.id,
          tool_name: "deploy_preview",
          agent_id: agent.id,
          status: "allow"
        })

      {:ok, _} = ToolGrants.revoke(latest.id)
      result = Server.call_tool("deploy_preview", %{}, agent)
      assert result == %{error: "Tool not authorized", decision: "revoked"}

      # static tools still work
      assert is_list(Server.call_tool("list_projects", %{}, agent))
      # silence unused
      assert grant.id
    end

    test "cross-tenant agent cannot list or call another company's dynamic tool", %{
      company_a: company_a,
      agent_b: agent_b
    } do
      {:ok, _} =
        ToolRegistry.register(company_a.id, %{
          "name" => "tenant_secret",
          "description" => "A only"
        })

      {:ok, agent_a} =
        Agents.create_agent(%{
          company_id: company_a.id,
          name: "A again",
          role: :qa_engineer,
          status: :idle
        })

      {:ok, _} =
        ToolGrants.create_grant(%{
          company_id: company_a.id,
          tool_name: "tenant_secret",
          agent_id: agent_a.id,
          status: "allow"
        })

      refute Enum.any?(Server.tools_for(agent_b), &(&1.name == "tenant_secret"))

      assert Server.call_tool("tenant_secret", %{}, agent_b) == %{
               error: "Tool not authorized",
               decision: "deny"
             }
    end

    test "authorized dynamic call with nil plugin_id returns plugin_not_found", %{
      agent: agent,
      company: company
    } do
      {:ok, _} =
        ToolGrants.create_grant(%{
          company_id: company.id,
          tool_name: "deploy_preview",
          agent_id: agent.id,
          status: "allow"
        })

      assert Server.call_tool("deploy_preview", %{}, agent) == %{
               success: false,
               dynamic: true,
               tool: "deploy_preview",
               error: ":plugin_not_found"
             }
    end

    test "authorized dynamic call with missing plugin process returns plugin_not_found", %{
      agent: agent,
      company: company,
      plugin: plugin
    } do
      {:ok, _} =
        ToolRegistry.register(company.id, %{
          "name" => "missing_worker_tool",
          "description" => "plugin row exists, worker does not",
          "plugin_id" => plugin.id
        })

      {:ok, _} =
        ToolGrants.create_grant(%{
          company_id: company.id,
          tool_name: "missing_worker_tool",
          agent_id: agent.id,
          status: "allow"
        })

      assert Server.call_tool("missing_worker_tool", %{}, agent) == %{
               success: false,
               dynamic: true,
               tool: "missing_worker_tool",
               error: ":plugin_not_found"
             }
    end

    test "a disabled plugin is denied even while its stale worker and grant still exist", %{
      agent: agent,
      company: company,
      plugin: plugin
    } do
      {:ok, pid} = EchoToolWorker.start_link(plugin: plugin, company_id: company.id)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      {:ok, _tool} =
        ToolRegistry.register(company.id, %{
          "name" => "disabled_plugin_tool",
          "plugin_id" => plugin.id
        })

      {:ok, _grant} =
        ToolGrants.create_grant(%{
          company_id: company.id,
          tool_name: "disabled_plugin_tool",
          agent_id: agent.id,
          status: "allow"
        })

      assert ToolGrants.authorize_call(company.id, agent.id, "disabled_plugin_tool") == :allow
      assert %{success: true} = Server.call_tool("disabled_plugin_tool", %{}, agent)

      assert {:ok, _disabled} =
               Skills.update_plugin(plugin, %{enabled: false, status: "disabled"})

      assert Process.alive?(pid)
      assert ToolGrants.authorize_call(company.id, agent.id, "disabled_plugin_tool") == :deny
      refute Enum.any?(Server.tools_for(agent), &(&1.name == "disabled_plugin_tool"))

      assert Server.call_tool("disabled_plugin_tool", %{}, agent) == %{
               error: "Tool not authorized",
               decision: "deny"
             }
    end

    test "a plugin tool that hangs returns a structured timeout, not an exit", %{
      agent: agent,
      company: company,
      plugin: plugin
    } do
      # Plugin workers run third-party code that makes network calls. A call
      # timeout is an *exit*, which call_tool/3's rescue cannot catch — the MCP
      # request used to 500 instead of telling the caller which tool hung.
      original = Application.get_env(:cympho, :mcp_dynamic_tool_timeout_ms)
      Application.put_env(:cympho, :mcp_dynamic_tool_timeout_ms, 150)

      on_exit(fn ->
        if original do
          Application.put_env(:cympho, :mcp_dynamic_tool_timeout_ms, original)
        else
          Application.delete_env(:cympho, :mcp_dynamic_tool_timeout_ms)
        end
      end)

      register_stub_worker(plugin.id, fn -> Process.sleep(:infinity) end)

      {:ok, _} =
        ToolRegistry.register(company.id, %{
          "name" => "hanging_tool",
          "description" => "never replies",
          "plugin_id" => plugin.id
        })

      {:ok, _} =
        ToolGrants.create_grant(%{
          company_id: company.id,
          tool_name: "hanging_tool",
          agent_id: agent.id,
          status: "allow"
        })

      assert %{success: false, dynamic: true, tool: "hanging_tool", error: error} =
               Server.call_tool("hanging_tool", %{}, agent)

      assert error =~ "tool_timeout"
      assert error =~ "hanging_tool"
    end

    test "a plugin worker that dies mid-call returns a structured error", %{
      agent: agent,
      company: company,
      plugin: plugin
    } do
      register_stub_worker(plugin.id, fn ->
        receive do
          _ -> exit(:boom)
        end
      end)

      {:ok, _} =
        ToolRegistry.register(company.id, %{
          "name" => "crashing_tool",
          "description" => "exits on call",
          "plugin_id" => plugin.id
        })

      {:ok, _} =
        ToolGrants.create_grant(%{
          company_id: company.id,
          tool_name: "crashing_tool",
          agent_id: agent.id,
          status: "allow"
        })

      assert %{success: false, dynamic: true, tool: "crashing_tool", error: error} =
               Server.call_tool("crashing_tool", %{}, agent)

      assert error =~ "plugin_exit"
    end

    test "dynamic call with unknown plugin_id is denied before dispatch", %{
      agent: agent,
      company: company
    } do
      {:ok, _} =
        ToolRegistry.register(company.id, %{
          "name" => "ghost_plugin_tool",
          "description" => "plugin id is not in this company",
          "plugin_id" => Ecto.UUID.generate()
        })

      {:ok, _} =
        ToolGrants.create_grant(%{
          company_id: company.id,
          tool_name: "ghost_plugin_tool",
          agent_id: agent.id,
          status: "allow"
        })

      assert Server.call_tool("ghost_plugin_tool", %{}, agent) == %{
               error: "Tool not authorized",
               decision: "deny"
             }
    end

    test "authorized dynamic call invokes the plugin worker", %{
      agent: agent,
      company: company
    } do
      u = System.unique_integer([:positive])

      {:ok, plugin} =
        Skills.create_plugin(%{
          company_id: company.id,
          identifier: "echo-worker-#{u}",
          version: "1.0.0",
          name: "Echo Worker",
          manifest: %{"name" => "echo-worker"},
          capabilities: ["expose:tools"],
          status: "active",
          enabled: true
        })

      {:ok, pid} = EchoToolWorker.start_link(plugin: plugin, company_id: company.id)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      {:ok, _} =
        ToolRegistry.register(company.id, %{
          "name" => "echo_now",
          "description" => "echo via worker",
          "plugin_id" => plugin.id
        })

      {:ok, _} =
        ToolGrants.create_grant(%{
          company_id: company.id,
          tool_name: "echo_now",
          agent_id: agent.id,
          status: "allow"
        })

      assert Server.call_tool("echo_now", %{"env" => "staging"}, agent) == %{
               success: true,
               dynamic: true,
               tool: "echo_now",
               plugin_id: plugin.id,
               result: %{
                 executed: "echo_now",
                 args: %{"env" => "staging"},
                 ctx: %{company_id: company.id, agent_id: agent.id}
               }
             }
    end

    test "worker default execute_tool is unsupported_tool", %{
      agent: agent,
      company: company
    } do
      u = System.unique_integer([:positive])

      {:ok, plugin} =
        Skills.create_plugin(%{
          company_id: company.id,
          identifier: "default-worker-#{u}",
          version: "1.0.0",
          name: "Default Worker",
          manifest: %{"name" => "default-worker"},
          capabilities: ["expose:tools"],
          status: "active",
          enabled: true
        })

      {:ok, pid} = DefaultToolWorker.start_link(plugin: plugin, company_id: company.id)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      {:ok, _} =
        ToolRegistry.register(company.id, %{
          "name" => "plain_tool",
          "description" => "default worker",
          "plugin_id" => plugin.id
        })

      {:ok, _} =
        ToolGrants.create_grant(%{
          company_id: company.id,
          tool_name: "plain_tool",
          agent_id: agent.id,
          status: "allow"
        })

      assert Server.call_tool("plain_tool", %{}, agent) == %{
               success: false,
               dynamic: true,
               tool: "plain_tool",
               error: ":unsupported_tool"
             }
    end
  end

  describe "HostServices.expose_tool/3-4" do
    test "registers via capability gate with company_id arg", %{
      plugin: plugin,
      company_a: company_a
    } do
      assert {:ok, exposed} =
               HostServices.expose_tool(
                 plugin.id,
                 company_a.id,
                 %{
                   "name" => "plugin_echo",
                   "description" => "Echoes",
                   "inputSchema" => %{"type" => "object"}
                 },
                 ["expose:tools"]
               )

      assert exposed.name == "plugin_echo"
      assert exposed.company_id == company_a.id
      assert exposed.plugin_id == plugin.id
      assert {:ok, _} = ToolRegistry.get_active(company_a.id, "plugin_echo")
    end

    test "registers via plugin company when definition omits company_id", %{plugin: plugin} do
      assert {:ok, exposed} =
               HostServices.expose_tool(
                 plugin.id,
                 %{"name" => "from_plugin_row", "description" => "resolved"},
                 ["expose:tools"]
               )

      assert exposed.company_id == plugin.company_id
    end

    test "3-arity ignores forged company_id and binds plugin company only", %{
      plugin: plugin,
      company_a: company_a,
      company_b: company_b
    } do
      assert {:ok, exposed} =
               HostServices.expose_tool(
                 plugin.id,
                 %{
                   "name" => "forged_3arity",
                   "company_id" => company_b.id,
                   "description" => "must not land on B"
                 },
                 ["expose:tools"]
               )

      assert exposed.company_id == company_a.id
      assert exposed.company_id == plugin.company_id
      assert ToolRegistry.get_active(company_b.id, "forged_3arity") == {:error, :not_found}
      assert {:ok, _} = ToolRegistry.get_active(company_a.id, "forged_3arity")
    end

    test "unauthorized without capability", %{plugin: plugin, company_a: company_a} do
      assert {:error, :unauthorized} =
               HostServices.expose_tool(
                 plugin.id,
                 company_a.id,
                 %{"name" => "nope"},
                 []
               )
    end

    test "disabled plugins cannot expose new tools", %{plugin: plugin, company_a: company_a} do
      assert {:ok, _disabled} =
               Skills.update_plugin(plugin, %{enabled: false, status: "disabled"})

      assert {:error, :plugin_inactive} =
               HostServices.expose_tool(
                 plugin.id,
                 company_a.id,
                 %{"name" => "disabled_registration"},
                 ["expose:tools"]
               )

      assert {:error, :not_found} =
               ToolRegistry.get_active(company_a.id, "disabled_registration")
    end

    test "rejects forged company_id when using 4-arity company scope", %{
      plugin: plugin,
      company_a: company_a,
      company_b: company_b
    } do
      # 4-arity binds plugin company only; definition company_id is ignored.
      assert {:ok, exposed} =
               HostServices.expose_tool(
                 plugin.id,
                 company_a.id,
                 %{
                   "name" => "scoped_tool",
                   "company_id" => company_b.id,
                   "description" => "must stay on A"
                 },
                 ["expose:tools"]
               )

      assert exposed.company_id == company_a.id
      assert ToolRegistry.get_active(company_b.id, "scoped_tool") == {:error, :not_found}
      assert {:ok, _} = ToolRegistry.get_active(company_a.id, "scoped_tool")
    end

    test "4-arity rejects foreign company_id arg", %{
      plugin: plugin,
      company_b: company_b
    } do
      assert {:error, :invalid_company_scope} =
               HostServices.expose_tool(
                 plugin.id,
                 company_b.id,
                 %{"name" => "foreign_arg_tool", "description" => "must reject"},
                 ["expose:tools"]
               )

      assert ToolRegistry.get_active(company_b.id, "foreign_arg_tool") == {:error, :not_found}
    end
  end

  # Stands in for a plugin worker so Plugins.Runtime.whereis/1 finds a process
  # we control. The real worker machinery is not needed to exercise how the MCP
  # server handles one that hangs or dies.
  defp register_stub_worker(plugin_id, body) do
    test_pid = self()

    pid =
      spawn(fn ->
        {:ok, _} = Registry.register(Cympho.Plugins.ProcessRegistry, plugin_id, nil)
        send(test_pid, :stub_registered)
        body.()
      end)

    assert_receive :stub_registered, 2_000
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
  end
end
