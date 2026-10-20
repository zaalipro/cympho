defmodule Cympho.T1Review.Accounting3RefusalRemedyTest do
  # Finding accounting-3: the unpriceable-runtime refusal cannot be fixed in
  # the product (its pricing remedy cannot work for runtimes that report no
  # usage), and default hires always hit it. The default-hire half is
  # reproduced in astra_default_runtimes_unpriceable_test.exs and the
  # form-save half in astra_3_pricing_dropped_on_save_test.exs.
  use CymphoWeb.LiveCase, async: false

  alias Cympho.{Agents, Comments, Companies, Finances, Issues, Orchestrator, Runtime}
  alias Cympho.RuntimeProfiles
  alias Cympho.Adapters.{CodexAdapter, ProcessAdapter}

  @moduletag :capture_log
  @moduletag membership_role: "admin"

  # The built-in process-codex / codex-mini list price for gpt-5.4-mini.
  @list_rates %{
    "input_usd_per_mtok" => "0.75",
    "output_usd_per_mtok" => "4.50",
    "cached_input_usd_per_mtok" => "0.075"
  }

  @owner_rates %{
    "input_usd_per_mtok" => "1.00",
    "output_usd_per_mtok" => "8.00",
    "cached_input_usd_per_mtok" => "0.10"
  }

  @qwen_rates %{
    "input_usd_per_mtok" => "0.10",
    "output_usd_per_mtok" => "0.40",
    "cached_input_usd_per_mtok" => "0.02"
  }

  @blank_rates %{
    "input_usd_per_mtok" => "",
    "output_usd_per_mtok" => "",
    "cached_input_usd_per_mtok" => ""
  }

  setup do
    unless Process.whereis(Cympho.OrchestratorRegistry) do
      start_supervised!({Registry, keys: :unique, name: Cympho.OrchestratorRegistry})
    end

    :ok
  end

  test "a Cursor agent's refusal offers flat-rate billing, not pricing" do
    %{agent: agent, issue: issue} = refused_cursor_fixture()

    {:ok, pid} = Orchestrator.start_and_run(issue, agent.id)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000

    # Cursor reports no usage, so pricing could never make it priceable.
    assert [refusal] =
             issue.id
             |> Comments.list_comments()
             |> Enum.filter(&(&1.body =~ "does not report a USD cost"))

    assert refusal.body =~ "company hard stop of 100 USD (monthly)"
    assert refusal.body =~ "mark the agent flat-rate"
    refute refusal.body =~ "pricing"
  end

  test "pricing saved through the Billing fieldset lets a process-codex agent run", %{
    conn: conn
  } do
    {:ok, _policy} = block_policy(current_company_id())

    # An agent hired before the built-in profile carried pricing.
    {:ok, agent} =
      Agents.create_agent(
        scoped_attrs(%{
          name: "T1 Review Unpriced Codex",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: "process-codex" |> RuntimeProfiles.config() |> Map.delete("pricing"),
          runtime_config: %{
            "profile_id" => "process-codex",
            "env" => %{"OPENAI_API_KEY" => "test-key"}
          }
        })
      )

    {:ok, issue} =
      Issues.create_issue(%{
        company_id: agent.company_id,
        title: "T1 Review priced codex issue",
        status: :todo,
        assignee_id: agent.id,
        assigned_role: "engineer"
      })

    on_exit(fn -> File.rm_rf(Cympho.Workspace.workspace_path(issue.id)) end)

    assert {:error, {:budget_unpriceable_runtime, %{reporting: :tokens}}} =
             Runtime.preflight(issue, with_fake_codex(agent))

    {:ok, view, _html} = live(conn, "/agents/#{agent.id}?tab=configuration")

    view
    |> form("form[phx-submit='config_save']", %{
      "agent" => %{
        "pricing" => %{
          "input_usd_per_mtok" => "1.00",
          "output_usd_per_mtok" => "8.00",
          "cached_input_usd_per_mtok" => "0.10"
        }
      }
    })
    |> render_submit()

    {:ok, saved} = Agents.get_agent(agent.id)

    assert saved.runtime_config["pricing"] == %{
             "gpt-5.4-mini" => %{
               "input_usd_per_mtok" => "1.00",
               "output_usd_per_mtok" => "8.00",
               "cached_input_usd_per_mtok" => "0.10"
             }
           }

    # The run settles against the rates the owner entered.
    assert {:ok, context} = Runtime.preflight(issue, with_fake_codex(saved))
    assert context.metadata["pricing"]["basis"] == "agent_pricing"
    assert context.metadata["pricing"]["input_usd_per_mtok"] == "1.00"
  end

  for {switch, label} <- [preset: "a quick preset", profile_select: "the profile select"] do
    test "#{label} does not carry the previous model's rates to the new model", %{
      conn: conn
    } do
      {:ok, agent} =
        Agents.create_agent(
          scoped_attrs(%{
            name: "T1 Review Qwen Agent",
            role: :engineer,
            status: :idle,
            adapter: :openai_chat,
            config: RuntimeProfiles.config("openai-chat-qwen-dashscope-flash"),
            runtime_config: %{
              "profile_id" => "openai-chat-qwen-dashscope-flash",
              "pricing" => %{"qwen3.6-flash" => @qwen_rates}
            }
          })
        )

      {:ok, view, _html} = live(conn, "/agents/#{agent.id}?tab=configuration")

      # Switch to codex-mini (gpt-5.4-mini), then save the form as rendered.
      switch_to_codex_mini(view, unquote(switch))
      view |> form("form[phx-submit='config_save']") |> render_submit()

      {:ok, saved} = Agents.get_agent(agent.id)
      assert RuntimeProfiles.from_agent(saved) == "codex-mini"
      assert saved.runtime_config["pricing"] == %{"qwen3.6-flash" => @qwen_rates}

      # gpt-5.4-mini runs settle at the codex-mini list price, not Qwen's.
      assert %{"basis" => "agent_pricing", "model" => "gpt-5.4-mini"} =
               pricing = pricing_snapshot(saved, CodexAdapter)

      assert Map.take(pricing, Map.keys(@list_rates)) == @list_rates
    end
  end

  test "clearing a model's rates restores the profile's rates while other models keep theirs",
       %{conn: conn} do
    {:ok, _policy} = block_policy(current_company_id())

    agent =
      codex_agent(RuntimeProfiles.config("process-codex"), %{
        "pricing" => %{"gpt-5.4-mini" => @owner_rates, "qwen3.6-flash" => @qwen_rates}
      })

    issue = issue_for(agent)

    {:ok, view, _html} = live(conn, "/agents/#{agent.id}?tab=configuration")

    view
    |> form("form[phx-submit='config_save']", %{"agent" => %{"pricing" => @blank_rates}})
    |> render_submit()

    {:ok, saved} = Agents.get_agent(agent.id)
    assert saved.runtime_config["pricing"] == %{"qwen3.6-flash" => @qwen_rates}

    # The cleared model falls back to the profile's rates under the hard stop.
    assert {:ok, context} = Runtime.preflight(issue, with_fake_codex(saved))
    assert %{"basis" => "agent_pricing"} = pricing = context.metadata["pricing"]
    assert Map.take(pricing, Map.keys(@list_rates)) == @list_rates
  end

  test "the Billing fieldset rejects invalid or incomplete rates without saving", %{conn: conn} do
    agent = codex_agent(RuntimeProfiles.config("process-codex"))

    {:ok, view, _html} = live(conn, "/agents/#{agent.id}?tab=configuration")

    for {rates, message} <- [
          {%{"input_usd_per_mtok" => "-1", "output_usd_per_mtok" => "4.50"},
           "Billing rates must be zero or positive USD amounts per million tokens."},
          {%{"input_usd_per_mtok" => "abc", "output_usd_per_mtok" => "4.50"},
           "Billing rates must be zero or positive USD amounts per million tokens."},
          {%{"input_usd_per_mtok" => "0.75", "output_usd_per_mtok" => ""},
           "Billing needs both an input and an output rate."}
        ] do
      view
      |> form("form[phx-submit='config_save']", %{"agent" => %{"pricing" => rates}})
      |> render_submit()

      flash = :sys.get_state(view.pid).socket.assigns.flash
      assert Phoenix.Flash.get(flash, :error) == message
    end

    {:ok, saved} = Agents.get_agent(agent.id)
    assert saved.runtime_config == agent.runtime_config
    assert saved.config == agent.config
  end

  test "switching a flat-rate agent back to metered prices its runs again", %{conn: conn} do
    agent =
      codex_agent(
        "process-codex"
        |> RuntimeProfiles.config()
        |> Map.put("billing_mode", "flat_rate")
      )

    assert %{"basis" => "flat_rate"} = pricing_snapshot(agent, ProcessAdapter)

    {:ok, view, _html} = live(conn, "/agents/#{agent.id}?tab=configuration")

    view
    |> form("form[phx-submit='config_save']", %{"agent" => %{"billing_mode" => "metered"}})
    |> render_submit()

    {:ok, saved} = Agents.get_agent(agent.id)
    assert saved.runtime_config["billing_mode"] == "metered"
    assert %{"basis" => "agent_pricing"} = pricing = pricing_snapshot(saved, ProcessAdapter)
    assert Map.take(pricing, Map.keys(@list_rates)) == @list_rates
  end

  test "the agent page shows the spending-limit refusal until billing is saved", %{conn: conn} do
    {:ok, _policy} = block_policy(current_company_id())

    # With autonomy on, an otherwise configured agent reports Ready, not
    # "Review mode only".
    original = Application.get_env(:cympho, :orchestrator, [])
    Application.put_env(:cympho, :orchestrator, Keyword.put(original, :enabled, true))
    on_exit(fn -> Application.put_env(:cympho, :orchestrator, original) end)

    # An agent hired before the built-in profile carried pricing, with a
    # command that exists so the refusal is the only blocker.
    agent =
      codex_agent(
        "process-codex"
        |> RuntimeProfiles.config()
        |> Map.delete("pricing")
        |> Map.put("command", fake_cli!("codex"))
      )

    ready = "is set up and ready to run."
    refused = "A spending limit stops"

    # Neither tab reports Ready while dispatch refuses the agent.
    {:ok, _view, html} = live(conn, "/agents/#{agent.id}")
    assert html =~ refused
    assert html =~ "tab=configuration#agent-billing"
    refute html =~ ready

    {:ok, view, html} = live(conn, "/agents/#{agent.id}?tab=configuration")
    assert html =~ refused
    assert html =~ "company hard stop of 100 USD (monthly)"
    assert html =~ "Add pricing for gpt-5.4-mini"
    refute html =~ ready

    html =
      view
      |> form("form[phx-submit='config_save']", %{"agent" => %{"pricing" => @owner_rates}})
      |> render_submit()

    # Once billing is saved, both tabs report Ready.
    assert html =~ ready
    refute html =~ refused
    refute html =~ "company hard stop of 100 USD (monthly)"

    {:ok, _view, html} = live(conn, "/agents/#{agent.id}")
    assert html =~ ready
    refute html =~ refused
  end

  defp refused_cursor_fixture do
    unique = System.unique_integer([:positive])

    {:ok, company} =
      Companies.create_company(%{
        name: "T1 Review Cursor #{unique}",
        slug: "t1-review-cursor-#{unique}"
      })

    {:ok, agent} =
      Agents.create_agent(%{
        company_id: company.id,
        name: "T1 Review Cursor #{unique}",
        role: :engineer,
        status: :idle,
        adapter: :cursor,
        config: %{"command" => fake_cli!("agent"), "model" => "gpt-5"}
      })

    {:ok, _policy} = block_policy(company.id)

    {:ok, issue} =
      Issues.create_issue(%{
        company_id: company.id,
        title: "T1 Review cursor issue #{unique}",
        status: :todo,
        assignee_id: agent.id,
        assigned_role: "engineer"
      })

    {:ok, issue} = Issues.checkout_issue(issue, agent)
    on_exit(fn -> File.rm_rf(Cympho.Workspace.workspace_path(issue.id)) end)
    %{agent: agent, issue: issue}
  end

  # The Low RAM preset button, or the profile <select>, whose hook pushes
  # select_runtime_profile instead of a form change.
  defp switch_to_codex_mini(view, :preset),
    do: view |> element("[data-runtime-preset='low_ram']") |> render_click()

  defp switch_to_codex_mini(view, :profile_select) do
    view
    |> element("[data-testid='agent-configuration-panel']")
    |> render_hook("select_runtime_profile", %{"profile_id" => "codex-mini"})
  end

  defp block_policy(company_id) do
    Finances.create_budget_policy(%{
      company_id: company_id,
      scope: "company",
      period: "monthly",
      budget_limit_usd: Decimal.new("100.00"),
      action_on_exceed: "block"
    })
  end

  defp codex_agent(config, runtime_config \\ %{}) do
    {:ok, agent} =
      Agents.create_agent(
        scoped_attrs(%{
          name: "T1 Review Codex #{System.unique_integer([:positive])}",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: config,
          runtime_config:
            Map.merge(
              %{"profile_id" => "process-codex", "env" => %{"OPENAI_API_KEY" => "test-key"}},
              runtime_config
            )
        })
      )

    agent
  end

  defp issue_for(agent) do
    {:ok, issue} =
      Issues.create_issue(%{
        company_id: agent.company_id,
        title: "T1 Review billing issue #{System.unique_integer([:positive])}",
        status: :todo,
        assignee_id: agent.id,
        assigned_role: "engineer"
      })

    on_exit(fn -> File.rm_rf(Cympho.Workspace.workspace_path(issue.id)) end)
    issue
  end

  # The pricing snapshot a gpt-5.4-mini run of the saved agent settles against.
  defp pricing_snapshot(agent, adapter) do
    {:ok, pricing} =
      Finances.check_runtime_priceable(%{company_id: agent.company_id}, agent, adapter, %{
        "model" => "gpt-5.4-mini"
      })

    pricing
  end

  # Only the binary path changes, so preflight does not depend on a local
  # codex install; billing stays in runtime_config.
  defp with_fake_codex(agent) do
    {:ok, agent} =
      Agents.update_agent(agent, %{config: Map.put(agent.config, "command", fake_cli!("codex"))})

    agent
  end

  defp fake_cli!(name) do
    dir = Path.join(System.tmp_dir!(), "t1-review-#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    path = Path.join(dir, name)
    File.write!(path, "#!/bin/sh\ncat > /dev/null\necho done\n")
    File.chmod!(path, 0o755)
    path
  end
end
