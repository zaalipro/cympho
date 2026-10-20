defmodule CymphoWeb.AgentPricingProfileSwitchTest do
  # T1-fix gate item 1: adapter_config_base/2 used to shallow-merge
  # the existing config's "pricing" over the new profile's config, so pricing
  # kept in `config` replaces the profile's whole pricing map on a switch.
  use CymphoWeb.LiveCase, async: false

  alias Cympho.{Agents, Finances, RuntimeProfiles}
  alias Cympho.Adapters.CodexAdapter

  @moduletag :capture_log
  @moduletag membership_role: "admin"

  @list_rates %{
    "input_usd_per_mtok" => "0.75",
    "output_usd_per_mtok" => "4.50",
    "cached_input_usd_per_mtok" => "0.075"
  }

  @qwen_rates %{
    "input_usd_per_mtok" => "0.10",
    "output_usd_per_mtok" => "0.40",
    "cached_input_usd_per_mtok" => "0.02"
  }

  test "switching to codex-mini keeps its gpt-5.4-mini rates when config prices only Qwen",
       %{conn: conn} do
    {:ok, _policy} =
      Finances.create_budget_policy(%{
        company_id: current_company_id(),
        scope: "company",
        period: "monthly",
        budget_limit_usd: Decimal.new("100.00"),
        action_on_exceed: "block"
      })

    # Same as the existing profile-switch test, except the Qwen rates live in
    # config (the documented Pricing location), not runtime_config.
    {:ok, agent} =
      Agents.create_agent(
        scoped_attrs(%{
          name: "T1 Gate Qwen Config Agent",
          role: :engineer,
          status: :idle,
          adapter: :openai_chat,
          config:
            "openai-chat-qwen-dashscope-flash"
            |> RuntimeProfiles.config()
            |> Map.put("pricing", %{"qwen3.6-flash" => @qwen_rates}),
          runtime_config: %{"profile_id" => "openai-chat-qwen-dashscope-flash"}
        })
      )

    {:ok, view, _html} = live(conn, "/agents/#{agent.id}?tab=configuration")

    view
    |> element("[data-testid='agent-configuration-panel']")
    |> render_hook("select_runtime_profile", %{"profile_id" => "codex-mini"})

    view |> form("form[phx-submit='config_save']") |> render_submit()

    {:ok, saved} = Agents.get_agent(agent.id)
    assert RuntimeProfiles.from_agent(saved) == "codex-mini"

    # Under the company hard stop, a gpt-5.4-mini run is priceable.
    assert {:ok, %{"basis" => "agent_pricing"} = pricing} =
             Finances.check_runtime_priceable(
               %{company_id: saved.company_id},
               saved,
               CodexAdapter,
               %{"model" => "gpt-5.4-mini"}
             )

    assert Map.take(pricing, Map.keys(@list_rates)) == @list_rates

    # The Qwen rates survive, and codex-mini's own gpt-5.4-mini default rates
    # are kept alongside them.
    assert saved.config["pricing"]["qwen3.6-flash"] == @qwen_rates

    assert saved.config["pricing"]["gpt-5.4-mini"] == @list_rates,
           "saved config pricing: #{inspect(saved.config["pricing"])}"
  end
end
