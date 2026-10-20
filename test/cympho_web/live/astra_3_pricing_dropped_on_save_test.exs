defmodule CymphoWeb.T1Review.Astra3PricingDroppedOnSaveTest do
  # Finding astra-3: provide an executable owner recovery path for
  # unpriceable agents. An out-of-band pricing repair (the only recovery the
  # suite uses, Agents.update_agent/2) is lost on the next profile save.
  use CymphoWeb.LiveCase, async: false

  alias Cympho.{Agents, RuntimeProfiles}

  @moduletag membership_role: "admin"

  # Owner rates that differ from the built-in process-codex rates, plus a
  # model the profile does not price, so a save that rebuilt config from the
  # profile alone could not reproduce them.
  @pricing %{
    "gpt-5.4-mini" => %{
      "input_usd_per_mtok" => "0.60",
      "output_usd_per_mtok" => "3.60",
      "cached_input_usd_per_mtok" => "0.06"
    },
    "gpt-5.5" => %{
      "input_usd_per_mtok" => "1.25",
      "output_usd_per_mtok" => "10.00"
    }
  }

  test "saving the configuration tab keeps the agent's pricing and billing mode", %{
    conn: conn
  } do
    assert RuntimeProfiles.config("process-codex")["pricing"] != @pricing

    {:ok, agent} =
      Agents.create_agent(
        scoped_attrs(%{
          name: "T1 Review Priced Codex",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config:
            "process-codex"
            |> RuntimeProfiles.config()
            |> Map.put("pricing", @pricing)
            |> Map.put("billing_mode", "flat_rate"),
          runtime_config: %{"profile_id" => "process-codex"}
        })
      )

    {:ok, view, _html} = live(conn, "/agents/#{agent.id}?tab=configuration")

    # The owner changes only the concurrency and saves, keeping the profile.
    view
    |> form("form[phx-submit='config_save']", %{
      "agent" => %{
        "name" => agent.name,
        "title" => "",
        "role" => "engineer",
        "parent_id" => "",
        "runtime_profile_id" => "process-codex",
        "adapter" => "process",
        "max_concurrent_jobs" => "2"
      }
    })
    |> render_submit()

    {:ok, updated} = Agents.get_agent(agent.id)
    assert updated.max_concurrent_jobs == 2
    assert updated.config["pricing"] == @pricing
    assert updated.config["billing_mode"] == "flat_rate"
  end
end
