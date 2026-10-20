defmodule Cympho.T1Review.AstraFlatRateFallbackTest do
  # Finding astra-opus-missed-1: flat_rate billing_mode follows the agent into
  # fallback profiles on metered providers, bypassing the USD hard stop.
  use Cympho.DataCase, async: false

  import Mock

  alias Cympho.{Agents, Companies, Finances, HeartbeatEngine, Issues, Orchestrator}
  alias Cympho.{Runtime, RuntimeProfiles}
  alias Cympho.Adapters.MockAdapter
  alias Cympho.HeartbeatEngine.Run

  @moduletag :capture_log

  # gpt-5.4-mini rates that differ from the codex-mini / process-codex list
  # price (0.75 / 4.50 / 0.075): the agent's config, and its runtime_config.
  @config_mini_rates %{
    "input_usd_per_mtok" => "2.00",
    "output_usd_per_mtok" => "12.00",
    "cached_input_usd_per_mtok" => "0.20"
  }

  @agent_mini_rates %{
    "input_usd_per_mtok" => "3.00",
    "output_usd_per_mtok" => "20.00",
    "cached_input_usd_per_mtok" => "0.30"
  }

  @qwen_rates %{"input_usd_per_mtok" => "0.10", "output_usd_per_mtok" => "0.40"}

  setup do
    unless Process.whereis(Cympho.OrchestratorRegistry) do
      start_supervised!({Registry, keys: :unique, name: Cympho.OrchestratorRegistry})
    end

    MockAdapter.clear()
    on_exit(fn -> MockAdapter.clear() end)
    :ok
  end

  test "a flat-rate Cursor agent's process-codex fallback is not admitted as flat_rate" do
    %{company: company, agent: agent, issue: issue} = engineer_fixture()
    company_block_policy(company)

    # The owner marked the agent's own runtime (a Cursor subscription) flat-rate.
    {:ok, agent} =
      Agents.update_agent(agent, %{
        adapter: :cursor,
        config: Map.put(RuntimeProfiles.config("cursor-auto"), "billing_mode", "flat_rate"),
        runtime_config: %{
          "profile_id" => "cursor-auto",
          "fallback_profile_ids" => ["process-codex"]
        }
      })

    assert RuntimeProfiles.fallback_profile_ids(agent) == ["process-codex"]

    # The fallback preflight Orchestrator.prepare_runtime/2 runs for the
    # metered, token-only process-codex profile.
    fallback = RuntimeProfiles.get("process-codex")

    assert {:ok, context} =
             Runtime.preflight(issue, agent,
               adapter: :process,
               adapter_config: Map.put(fallback.config, "command", fake_codex!()),
               runtime_profile_id: fallback.id,
               runtime_env: %{}
             )

    # Priced at the fallback profile's own list price, not the agent's flat_rate.
    assert context.metadata["pricing"] == %{
             "basis" => "agent_pricing",
             "provider" => "openai",
             "model" => "gpt-5.4-mini",
             "input_usd_per_mtok" => "0.75",
             "output_usd_per_mtok" => "4.50",
             "cached_input_usd_per_mtok" => "0.075"
           }

    # The agent's own rates for the model (as the Billing fieldset saves
    # them) win over the fallback profile's.
    {:ok, agent} =
      Agents.update_agent(agent, %{
        runtime_config:
          Map.put(agent.runtime_config, "pricing", %{"gpt-5.4-mini" => @agent_mini_rates})
      })

    assert {:ok, context} =
             Runtime.preflight(issue, agent,
               adapter: :process,
               adapter_config: Map.put(fallback.config, "command", fake_codex!()),
               runtime_profile_id: fallback.id,
               runtime_env: %{}
             )

    assert context.metadata["pricing"] ==
             Map.merge(@agent_mini_rates, %{
               "basis" => "agent_pricing",
               "provider" => "openai",
               "model" => "gpt-5.4-mini"
             })
  end

  test "a flat-rate agent's unpriced token-only fallback is refused under the hard stop" do
    %{company: company, agent: agent, issue: issue} = engineer_fixture()
    policy = company_block_policy(company)

    {:ok, agent} =
      Agents.update_agent(agent, %{
        adapter: :cursor,
        config: Map.put(RuntimeProfiles.config("cursor-auto"), "billing_mode", "flat_rate"),
        runtime_config: %{
          "profile_id" => "cursor-auto",
          "fallback_profile_ids" => ["openai-chat-qwen-dashscope-flash"]
        }
      })

    # openai_chat reports only tokens, and this profile carries no pricing.
    fallback = RuntimeProfiles.get("openai-chat-qwen-dashscope-flash")

    assert {:error, {:budget_unpriceable_runtime, info}} =
             Runtime.preflight(issue, agent,
               adapter: :openai_chat,
               adapter_config: Map.put(fallback.config, "api_key", "test-key"),
               runtime_profile_id: fallback.id,
               runtime_env: %{}
             )

    assert info.policy_id == policy.id
    assert info.reporting == :tokens
    assert info.model == "qwen3.6-flash"
  end

  test "a fallback run's reported cost is not discarded as flat_rate" do
    {:ok, %{company: company, agents: [ceo | _], seed_issues: [issue | _]}} =
      Companies.create_autonomous_company(%{
        name: "T1 Review Flat Co #{System.unique_integer([:positive])}",
        issue_prefix: "TRF",
        engineer_count: 1
      })

    {:ok, issue} = Issues.checkout_issue(issue, ceo, :ceo)
    on_exit(fn -> File.rm_rf(Cympho.Workspace.workspace_path(issue.id)) end)

    {:ok, ceo} =
      Agents.update_agent(ceo, %{
        config: %{"command" => "cz", "billing_mode" => "flat_rate"},
        runtime_config: %{
          "profile_id" => "claude-cz",
          "fallback_profile_ids" => ["openai-chat-qwen-dashscope-flash"]
        }
      })

    MockAdapter.script(ceo.id, issue.id, [
      %{error: {:provider_failure, :rate_limited, "HTTP 429 Too Many Requests"}},
      %{
        result: %{
          "result" => "Still working on it.",
          "usage" => %{"input_tokens" => 1_000, "output_tokens" => 200},
          "total_cost_usd" => 0.42
        }
      }
    ])

    with_mock Cympho.Adapters, [:passthrough],
      resolve: fn %{config: config} -> {:ok, MockAdapter, config} end do
      {:ok, pid} = Orchestrator.start_and_run(issue, ceo.id)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
    end

    assert %Run{} =
             fallback =
             issue.id
             |> HeartbeatEngine.list_runs_for_issue()
             |> Enum.find(&(&1.adapter == "openai_chat"))

    assert fallback.input_tokens == 1_000

    cost_source = fallback.run_metadata["accounting"]["cost_source"]
    assert cost_source == "reported"
    # cost_usd is stored with scale 6, so compare values, not strings.
    assert Decimal.eq?(fallback.cost_usd, Decimal.new("0.42"))

    assert [_ | _] = Finances.list_token_usages(company.id)
  end

  # Pricing composes per model: fallback profile < agent config <
  # runtime_config. 1M input + 100k output tokens settle at 0.75 + 0.45 = 1.20
  # on the codex-mini list price, 2.00 + 1.20 = 3.20 on the config rates and
  # 3.00 + 2.00 = 5.00 on the runtime_config rates.
  for {label, runtime_pricing, rates, cost} <- [
        {"another model's", %{"qwen3.6-flash" => @qwen_rates}, @config_mini_rates, "3.20"},
        {"the same model's",
         %{"qwen3.6-flash" => @qwen_rates, "gpt-5.4-mini" => @agent_mini_rates},
         @agent_mini_rates, "5.00"}
      ] do
    test "a fallback run with #{label} runtime_config rates is priced and settled per model" do
      {:ok, %{company: company, agents: [ceo | _], seed_issues: [issue | _]}} =
        Companies.create_autonomous_company(%{
          name: "T1 Review Merge Co #{System.unique_integer([:positive])}",
          issue_prefix: "TRM",
          engineer_count: 1
        })

      {:ok, issue} = Issues.checkout_issue(issue, ceo, :ceo)
      on_exit(fn -> File.rm_rf(Cympho.Workspace.workspace_path(issue.id)) end)

      {:ok, ceo} =
        Agents.update_agent(ceo, %{
          config: %{
            "model" => "gpt-5.5",
            "pricing" => %{
              "gpt-5.5" => %{"input_usd_per_mtok" => "1.25", "output_usd_per_mtok" => "10.00"},
              "gpt-5.4-mini" => @config_mini_rates
            }
          },
          runtime_config: %{
            "fallback_profile_ids" => ["codex-mini"],
            "pricing" => unquote(Macro.escape(runtime_pricing))
          }
        })

      MockAdapter.script(ceo.id, issue.id, [
        %{error: {:provider_failure, :rate_limited, "HTTP 429 Too Many Requests"}},
        %{
          result: %{
            "result" => "Still working on it.",
            "usage" => %{"input_tokens" => 1_000_000, "output_tokens" => 100_000}
          }
        }
      ])

      with_mock Cympho.Adapters, [:passthrough],
        resolve: fn %{config: config} -> {:ok, MockAdapter, config} end do
        {:ok, pid} = Orchestrator.start_and_run(issue, ceo.id)
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
      end

      runs = HeartbeatEngine.list_runs_for_issue(issue.id)

      # The primary run keeps the config's rates for gpt-5.5, which
      # runtime_config does not list.
      assert %Run{} = primary = Enum.find(runs, &(&1.adapter != "codex"))
      assert primary.run_metadata["pricing"]["model"] == "gpt-5.5"
      assert primary.run_metadata["pricing"]["input_usd_per_mtok"] == "1.25"

      assert %Run{} = fallback = Enum.find(runs, &(&1.adapter == "codex"))

      assert Map.take(fallback.run_metadata["pricing"], Map.keys(@agent_mini_rates)) ==
               unquote(Macro.escape(rates))

      assert fallback.run_metadata["accounting"]["cost_source"] == "priced"
      assert Decimal.eq?(fallback.cost_usd, Decimal.new(unquote(cost)))

      assert Enum.any?(
               Finances.list_token_usages(company.id),
               &Decimal.eq?(&1.cost_usd, Decimal.new(unquote(cost)))
             )
    end
  end

  defp engineer_fixture do
    unique = System.unique_integer([:positive])

    {:ok, company} =
      Companies.create_company(%{
        name: "T1 Review Flat #{unique}",
        slug: "t1-review-flat-#{unique}"
      })

    {:ok, agent} =
      Agents.create_agent(%{
        company_id: company.id,
        name: "T1 Review Flat Agent #{unique}",
        role: :engineer,
        status: :idle,
        adapter: :openai_chat,
        config: %{"provider" => "openai", "model" => "gpt-5.4-mini"}
      })

    {:ok, issue} =
      Issues.create_issue(%{
        company_id: company.id,
        title: "T1 Review flat issue #{unique}",
        status: :todo,
        assignee_id: agent.id,
        assigned_role: "engineer"
      })

    {:ok, issue} = Issues.checkout_issue(issue, agent)
    on_exit(fn -> File.rm_rf(Cympho.Workspace.workspace_path(issue.id)) end)
    %{company: company, agent: agent, issue: issue}
  end

  defp company_block_policy(company) do
    {:ok, policy} =
      Finances.create_budget_policy(%{
        company_id: company.id,
        scope: "company",
        period: "monthly",
        budget_limit_usd: Decimal.new("100.00"),
        action_on_exceed: "block"
      })

    policy
  end

  defp fake_codex! do
    dir = Path.join(System.tmp_dir!(), "t1-review-codex-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    path = Path.join(dir, "codex")
    File.write!(path, "#!/bin/sh\ncat > /dev/null\necho done\n")
    File.chmod!(path, 0o755)
    path
  end
end
