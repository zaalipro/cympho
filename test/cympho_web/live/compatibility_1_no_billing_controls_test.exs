defmodule CymphoWeb.T1Review.Compatibility1NoBillingControlsTest do
  # Finding compatibility-1: owners cannot set pricing or flat_rate anywhere in
  # the product, so non-Claude runtimes are refused after upgrade.
  use CymphoWeb.LiveCase, async: false

  alias Cympho.Agents

  @moduletag membership_role: "admin"

  test "the agent configuration tab offers billing controls", %{conn: conn} do
    {:ok, agent} =
      Agents.create_agent(
        scoped_attrs(%{
          name: "T1 Review Codex Hire",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: Cympho.RuntimeProfiles.config("process-codex"),
          runtime_config: %{"profile_id" => "process-codex"}
        })
      )

    {:ok, _view, html} = live(conn, "/agents/#{agent.id}?tab=configuration")

    form_field_names =
      ~r/name="([^"]+)"/
      |> Regex.scan(html, capture: :all_but_first)
      |> List.flatten()

    assert Enum.any?(form_field_names, &(&1 =~ ~r/billing_mode|pricing|usd_per_mtok/)),
           "no billing_mode/pricing field among #{length(form_field_names)} form fields"
  end

  test "a configuration save cannot mark the agent flat-rate", %{conn: conn} do
    {:ok, agent} =
      Agents.create_agent(
        scoped_attrs(%{
          name: "T1 Review Cursor Hire",
          role: :engineer,
          status: :idle,
          adapter: :cursor,
          config: Cympho.RuntimeProfiles.config("cursor-auto"),
          runtime_config: %{"profile_id" => "cursor-auto"}
        })
      )

    {:ok, view, _html} = live(conn, "/agents/#{agent.id}?tab=configuration")

    # Submitted as the event (bypassing the DOM field check) so any accepted
    # spelling of the setting would persist.
    render_submit(view, "config_save", %{
      "agent" => %{
        "name" => agent.name,
        "title" => "",
        "role" => "engineer",
        "parent_id" => "",
        "runtime_profile_id" => "cursor-auto",
        "adapter" => "cursor",
        "max_concurrent_jobs" => "2",
        "billing_mode" => "flat_rate"
      },
      "billing_mode" => "flat_rate"
    })

    {:ok, updated} = Agents.get_agent(agent.id)
    # The save itself went through.
    assert updated.max_concurrent_jobs == 2
    effective = Map.merge(updated.config || %{}, updated.runtime_config || %{})
    assert effective["billing_mode"] == "flat_rate"
  end
end
