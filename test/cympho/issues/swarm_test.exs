defmodule Cympho.Issues.SwarmTest do
  use Cympho.DataCase, async: true

  import Ecto.Query

  alias Cympho.Agents
  alias Cympho.Agents.Agent
  alias Cympho.Companies
  alias Cympho.Issues
  alias Cympho.Issues.Issue
  alias Cympho.Issues.Swarm
  alias Cympho.Issues.SwarmEvents
  alias Cympho.Proxies
  alias Cympho.Repo
  alias Cympho.Users
  alias Cympho.Wakes.AgentWake

  describe "normalize_config/1" do
    test "defaults to a local reviewable runtime instead of credential-gated providers" do
      config =
        Swarm.normalize_config(%{
          "swarm" => %{
            "enabled" => "true",
            "agent_count" => "5"
          }
        })

      assert config.enabled
      assert length(config.mix) == 5

      assert Enum.all?(config.mix, fn spec ->
               spec.adapter == :claude_code and
                 spec.model == "sonnet" and
                 spec.reasoning_effort == "medium"
             end)
    end

    test "keeps proxy routing to named profiles instead of raw proxy URLs" do
      config =
        Swarm.normalize_config(%{
          "swarm" => %{
            "enabled" => "true",
            "agent_count" => "2",
            "mix" => "researcher | codex | gpt-5.3 | socks5://127.0.0.1:9050",
            "proxy_enabled" => "true",
            "proxy_profile" => "socks5://127.0.0.1:9050",
            "proxy_pool" => """
            socks5://127.0.0.1:9050
            http://127.0.0.1:8080
            """
          }
        })

      assert config.enabled
      refute config.proxy.enabled
      assert config.proxy.profile == nil
      assert config.proxy.pool == []
      assert [%{proxy_profile: nil}] = config.mix
    end

    test "accepts structured managed proxy profiles and pools" do
      config =
        Swarm.normalize_config(%{
          swarm: %{
            enabled: true,
            agent_count: 4,
            mix: [%{role: :researcher, adapter: :codex}],
            proxy: %{
              enabled: true,
              profile: "managed-egress-a",
              pool: ["managed-egress-b", "managed-egress-c", "socks5://127.0.0.1:9050"]
            }
          }
        })

      assert config.enabled
      assert config.proxy.enabled
      assert config.proxy.profile == "managed-egress-a"
      assert config.proxy.pool == ["managed-egress-a", "managed-egress-b", "managed-egress-c"]
      assert [%{proxy_profile: nil}] = config.mix
    end

    test "uses saved proxy profiles for random and selected swarm proxy modes" do
      {:ok, company} =
        Companies.create_company(%{
          name: "Saved Proxy Swarm Co",
          slug: "saved-proxy-swarm-#{System.unique_integer([:positive])}"
        })

      {:ok, proxy_a} = create_proxy_profile(company.id, "egress-a", 10_801)
      {:ok, proxy_b} = create_proxy_profile(company.id, "egress-b", 10_802)

      random =
        Swarm.normalize_config(%{
          "company_id" => company.id,
          "swarm" => %{
            "enabled" => "true",
            "agent_count" => "2",
            "mix_rows" => %{
              "0" => %{
                "enabled" => "true",
                "role" => "researcher",
                "harness" => "openai_chat",
                "model" => "qwen3.6-flash",
                "reasoning_effort" => "high"
              }
            },
            "proxy_mode" => "random"
          }
        })

      assert random.proxy.enabled
      assert random.proxy.mode == "random"
      assert random.proxy.pool == ["egress-a", "egress-b"]
      assert [%{reasoning_effort: "high", model: "qwen3.6-flash"}] = random.mix

      selected =
        Swarm.normalize_config(%{
          "company_id" => company.id,
          "swarm" => %{
            "enabled" => "true",
            "agent_count" => "2",
            "proxy_mode" => "selected",
            "proxy_profile_ids" => [proxy_b.id, proxy_a.id]
          }
        })

      assert selected.proxy.enabled
      assert selected.proxy.mode == "selected"
      assert selected.proxy.pool == ["egress-a", "egress-b"]
      assert MapSet.new(selected.proxy.profile_ids) == MapSet.new([proxy_b.id, proxy_a.id])
    end

    test "treats omitted structured row checkbox as disabled" do
      config =
        Swarm.normalize_config(%{
          "swarm" => %{
            "enabled" => "true",
            "agent_count" => "3",
            "mix_rows" => %{
              "0" => %{
                "enabled" => "true",
                "role" => "product_manager",
                "harness" => "openai_chat",
                "model" => "qwen3.6-flash",
                "reasoning_effort" => "medium"
              },
              "1" => %{
                "role" => "designer",
                "harness" => "openai_chat",
                "model" => "qwen3.6-flash",
                "reasoning_effort" => "low"
              }
            }
          }
        })

      assert [%{role: :product_manager, reasoning_effort: "medium"}] = config.mix
    end

    test "accepts process preset harnesses for CLI-backed swarms" do
      config =
        Swarm.normalize_config(%{
          "swarm" => %{
            "enabled" => "true",
            "agent_count" => "2",
            "mix_rows" => %{
              "0" => %{
                "enabled" => "true",
                "role" => "researcher",
                "harness" => "process:kimi_code",
                "model" => "kimi-code/kimi-for-coding",
                "reasoning_effort" => "medium"
              },
              "1" => %{
                "enabled" => "true",
                "role" => "designer",
                "harness" => "cline",
                "model" => "anthropic/claude-sonnet-4.6",
                "reasoning_effort" => "high"
              }
            }
          }
        })

      assert [
               %{
                 adapter: :process,
                 process_preset: "kimi_code",
                 model: "kimi-code/kimi-for-coding"
               },
               %{adapter: :process, process_preset: "cline", reasoning_effort: "high"}
             ] = config.mix
    end
  end

  describe "create_issue/1 with swarm enabled" do
    test "ignores user-supplied swarm params for non-admin members" do
      {:ok, company} =
        Companies.create_company(%{
          name: "Swarm Member Co",
          slug: "swarm-member-#{System.unique_integer([:positive])}"
        })

      {:ok, user} =
        Users.create_user(%{
          email: "swarm-member-#{System.unique_integer([:positive])}@example.com",
          name: "Member"
        })

      {:ok, _membership} =
        Companies.create_membership(%{
          user_id: user.id,
          company_id: company.id,
          role: "member",
          is_board_member: false
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Member tries swarm",
          description: "This should stay a normal issue.",
          status: :todo,
          company_id: company.id,
          actor_type: "user",
          actor_id: user.id,
          swarm: %{
            enabled: true,
            agent_count: "2"
          }
        })

      assert issue.status == :todo
      refute issue.monitor_state["swarm"]
      assert Issues.list_child_issues(issue.id) == []
    end

    test "configures process preset temporary agents for CLI-backed workers" do
      {:ok, company} =
        Companies.create_company(%{
          name: "Swarm CLI Co",
          slug: "swarm-cli-#{System.unique_integer([:positive])}"
        })

      {:ok, ceo} =
        Agents.create_agent(%{
          name: "Swarm CLI CEO",
          role: :ceo,
          status: :idle,
          company_id: company.id
        })

      {:ok, _cto} =
        Agents.create_agent(%{
          name: "Swarm CLI CTO",
          role: :cto,
          status: :idle,
          company_id: company.id
        })

      {:ok, parent} =
        Issues.create_issue(%{
          title: "Compare CLI-backed swarm worker",
          description: "CEO should launch a Kimi-backed worker packet.",
          status: :todo,
          priority: :medium,
          company_id: company.id,
          assigned_role: "ceo",
          assignee_id: ceo.id,
          swarm: %{
            enabled: true,
            agent_count: "1",
            mix_rows: %{
              "0" => %{
                "enabled" => "true",
                "role" => "researcher",
                "harness" => "process:kimi_code",
                "model" => "kimi-code/kimi-for-coding",
                "reasoning_effort" => "medium"
              }
            }
          }
        })

      [temp_agent_id] = parent.monitor_state["swarm"]["temporary_agent_ids"]
      {:ok, temp_agent} = Agents.get_agent(temp_agent_id)

      assert temp_agent.adapter == :process
      assert temp_agent.config["process_preset"] == "kimi_code"
      assert temp_agent.config["command"] == "kimi"
      assert temp_agent.config["provider"] == "moonshot"
      assert temp_agent.config["model"] == "kimi-code/kimi-for-coding"
      assert temp_agent.config["model_arg_template"] == ["-m", "{{model}}"]

      assert temp_agent.config["prompt_arg_template"] == [
               "-p",
               "{{prompt}}",
               "--output-format",
               "stream-json"
             ]

      assert temp_agent.config["prompt_stdin"] == false
      assert temp_agent.runtime_config["swarm"]["process_preset"] == "kimi_code"

      assert [
               %{
                 "harness" => "process",
                 "process_preset" => "kimi_code",
                 "model" => "kimi-code/kimi-for-coding"
               }
             ] = parent.monitor_state["swarm"]["mix"]
    end

    test "creates temporary non-engineer agents, worker issues, and CTO to CEO blockers" do
      {:ok, company} =
        Companies.create_company(%{
          name: "Swarm Co",
          slug: "swarm-co-#{System.unique_integer([:positive])}"
        })

      {:ok, ceo} =
        Agents.create_agent(%{
          name: "Swarm CEO",
          role: :ceo,
          status: :idle,
          company_id: company.id
        })

      {:ok, cto} =
        Agents.create_agent(%{
          name: "Swarm CTO",
          role: :cto,
          status: :idle,
          company_id: company.id
        })

      {:ok, parent} =
        Issues.create_issue(%{
          title: "Explore expansion plan",
          description: "CEO should coordinate a multi-role recommendation.",
          status: :todo,
          priority: :high,
          company_id: company.id,
          assigned_role: "ceo",
          assignee_id: ceo.id,
          swarm: %{
            enabled: true,
            agent_count: "4",
            mix: """
            product_manager | claude_code | sonnet | medium
            designer | codex | gpt-5.3-high-fast | high
            researcher | openai_chat | qwen3.6-flash | low
            """,
            proxy_enabled: true,
            proxy_profile: "managed-egress-a"
          }
        })

      assert parent.status == :blocked
      assert parent.assignee_id == ceo.id
      assert parent.monitor_state["swarm"]["status"] == "launched"
      assert parent.monitor_state["swarm"]["agent_count"] == 4

      assert parent.monitor_state["swarm"]["topology"] ==
               "parallel_workers_cto_synthesis_ceo_handoff"

      assert parent.monitor_state["swarm"]["proxy"]["profile"] == "managed-egress-a"

      assert parent.monitor_state["swarm"]["protocol"]["worker_contract"] ==
               "independent_delivery_packet_v1"

      assert Enum.any?(
               parent.monitor_state["swarm"]["protocol"]["rules"],
               &(&1["label"] == "Preserve dissent")
             )

      temp_agent_ids = parent.monitor_state["swarm"]["temporary_agent_ids"]
      assert length(temp_agent_ids) == 4

      temp_agents =
        Repo.all(from a in Agent, where: a.id in ^temp_agent_ids, order_by: a.name)

      assert length(temp_agents) == 4
      assert Enum.all?(temp_agents, &(&1.parent_id == ceo.id))
      assert Enum.all?(temp_agents, &(&1.config["temporary"] == true))
      assert Enum.all?(temp_agents, &(&1.config["one_time"] == true))
      assert Enum.all?(temp_agents, &(&1.config["hidden"] == true))
      assert Enum.all?(temp_agents, &(&1.config["reasoning_effort"] in ["medium", "high", "low"]))
      assert Enum.all?(temp_agents, &(&1.runtime_config["swarm"]["temporary"] == true))
      assert Enum.all?(temp_agents, &(&1.runtime_config["swarm"]["one_time"] == true))

      assert Enum.all?(
               temp_agents,
               &(&1.runtime_config["swarm"]["reasoning_effort"] in ["medium", "high", "low"])
             )

      assert Enum.all?(temp_agents, &is_binary(&1.runtime_config["swarm"]["lens"]["name"]))
      assert Enum.all?(temp_agents, &String.contains?(&1.instructions, "Work independently"))
      assert Enum.all?(temp_agents, &String.contains?(&1.instructions, "Reasoning effort:"))
      assert Enum.all?(temp_agents, &String.contains?(&1.instructions, "Dissent / alternative"))

      assert Enum.all?(
               temp_agents,
               &String.contains?(&1.instructions, "must be exactly `[delivery]`")
             )

      assert Enum.all?(
               temp_agents,
               &String.contains?(&1.instructions, "exact headings in order")
             )

      openai_temp_agents = Enum.filter(temp_agents, &(&1.adapter == :openai_chat))

      assert Enum.all?(
               openai_temp_agents,
               &String.contains?(
                 &1.config["system_prompt"],
                 "Start the response with exactly: [delivery]"
               )
             )

      assert Enum.all?(
               openai_temp_agents,
               &String.contains?(&1.config["system_prompt"], "swarm_worker_complete")
             )

      assert Enum.all?(
               openai_temp_agents,
               &String.contains?(
                 &1.config["system_prompt"],
                 "Use the exact packet headings in order"
               )
             )

      assert Enum.all?(
               temp_agents,
               &(&1.runtime_config["swarm"]["proxy_profile"] == "managed-egress-a")
             )

      refute Enum.any?(temp_agents, &(&1.role in [:engineer, :qa_engineer, :release_engineer]))
      refute Enum.any?(Agents.list_agents_by_company(company.id), &(&1.id in temp_agent_ids))
      refute Enum.any?(Agents.list_for_sidebar(company.id), &(&1.id in temp_agent_ids))

      refute Enum.any?(
               Agents.list_eligible_agents(:product_manager, company.id),
               &(&1.id in temp_agent_ids)
             )

      for temp_agent <- temp_agents do
        assert {:error, :not_found} = Agents.get_company_agent(company.id, temp_agent.id)
        assert {:ok, _direct_dispatch_agent} = Agents.get_agent(temp_agent.id)
      end

      children =
        Repo.all(from i in Issue, where: i.parent_id == ^parent.id, order_by: i.inserted_at)

      worker_issues = Enum.filter(children, &(&1.origin_type == "swarm_worker"))
      [cto_issue] = Enum.filter(children, &(&1.origin_type == "swarm_cto_review"))

      assert length(worker_issues) == 4
      assert Enum.all?(worker_issues, &(&1.status == :todo))
      assert Enum.all?(worker_issues, &(&1.assignee_id in temp_agent_ids))
      assert Enum.all?(worker_issues, &is_binary(&1.monitor_state["swarm"]["lens"]["name"]))
      assert Enum.all?(worker_issues, &String.contains?(&1.description, "Independent first pass"))
      assert Enum.all?(worker_issues, &String.contains?(&1.description, "Dissent / alternative"))
      assert Enum.all?(worker_issues, &String.contains?(&1.description, "omit any heading"))
      assert Enum.all?(worker_issues, &String.contains?(&1.description, "swarm_worker_complete"))

      assert cto_issue.status == :blocked
      assert cto_issue.assigned_role == "cto"
      assert cto_issue.assignee_id == cto.id

      assert cto_issue.monitor_state["swarm"]["protocol"]["synthesis_contract"] ==
               "cto_synthesis_review_v1"

      assert String.contains?(cto_issue.description, "Do not concatenate packets")
      assert String.contains?(cto_issue.description, "Agreements:")
      assert String.contains?(cto_issue.description, "Dissent / contradictions:")
      assert String.contains?(cto_issue.description, "approve_issue")

      parent = Repo.preload(Repo.reload!(parent), :blocked_by)
      assert Enum.map(parent.blocked_by, & &1.id) == [cto_issue.id]

      cto_issue = Repo.preload(cto_issue, :blocked_by)

      assert MapSet.new(Enum.map(cto_issue.blocked_by, & &1.id)) ==
               MapSet.new(Enum.map(worker_issues, & &1.id))

      worker_ids = Enum.map(worker_issues, & &1.id)

      wakes =
        Repo.all(
          from wake in AgentWake,
            where: wake.issue_id in ^worker_ids,
            order_by: [asc: wake.inserted_at]
        )

      assert length(wakes) == 4
      assert Enum.all?(wakes, &(&1.reason == "swarm_worker_created"))
      assert Enum.all?(wakes, &(&1.status == "pending"))
      assert MapSet.new(Enum.map(wakes, & &1.agent_id)) == MapSet.new(temp_agent_ids)

      event_types =
        parent
        |> SwarmEvents.list_for_issue()
        |> Enum.map(& &1.event_type)

      assert "launch_started" in event_types
      assert "temporary_agents_created" in event_types
      assert "worker_issues_created" in event_types
      assert "cto_issue_created" in event_types
      assert "dependencies_linked" in event_types
      assert "parent_blocked_on_cto" in event_types
      assert "worker_wakes_enqueued" in event_types
      assert "launch_ready" in event_types

      assert Enum.take(event_types, 9) == [
               "launch_started",
               "temporary_agents_created",
               "worker_issues_created",
               "cto_issue_created",
               "dependencies_linked",
               "cto_blocked_on_workers",
               "parent_blocked_on_cto",
               "worker_wakes_enqueued",
               "launch_ready"
             ]
    end

    test "randomizes managed proxy pool across temporary worker assignments" do
      {:ok, company} =
        Companies.create_company(%{
          name: "Swarm Proxy Pool Co",
          slug: "swarm-proxy-pool-#{System.unique_integer([:positive])}"
        })

      {:ok, ceo} =
        Agents.create_agent(%{
          name: "Proxy Pool CEO",
          role: :ceo,
          status: :idle,
          company_id: company.id
        })

      {:ok, _cto} =
        Agents.create_agent(%{
          name: "Proxy Pool CTO",
          role: :cto,
          status: :idle,
          company_id: company.id
        })

      {:ok, parent} =
        Issues.create_issue(%{
          title: "Distribute swarm proxy profiles",
          description: "CEO should coordinate a proxy-pool swarm.",
          status: :todo,
          company_id: company.id,
          assigned_role: "ceo",
          assignee_id: ceo.id,
          swarm: %{
            enabled: true,
            agent_count: "6",
            mix: """
            product_manager | openai_chat | qwen3.6-flash
            designer | codex | gpt-5.3-high-fast
            researcher | claude_code | sonnet | managed-egress-fixed
            """,
            proxy_enabled: true,
            proxy_pool: """
            managed-egress-a
            managed-egress-b
            """
          }
        })

      assert parent.monitor_state["swarm"]["proxy"]["pool"] == [
               "managed-egress-a",
               "managed-egress-b"
             ]

      temp_agents =
        parent.monitor_state["swarm"]["temporary_agent_ids"]
        |> then(fn ids -> Repo.all(from a in Agent, where: a.id in ^ids, order_by: a.name) end)

      assigned_profiles = Enum.map(temp_agents, & &1.runtime_config["swarm"]["proxy_profile"])

      assert "managed-egress-fixed" in assigned_profiles
      assert "managed-egress-a" in assigned_profiles
      assert "managed-egress-b" in assigned_profiles

      assert Enum.all?(
               assigned_profiles,
               &(&1 in ["managed-egress-a", "managed-egress-b", "managed-egress-fixed"])
             )
    end
  end

  defp create_proxy_profile(company_id, name, port) do
    Proxies.create_proxy_profile(%{
      company_id: company_id,
      name: name,
      proxy_type: "socks5",
      host: "127.0.0.1",
      port: port
    })
  end
end
