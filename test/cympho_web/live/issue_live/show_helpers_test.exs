defmodule CymphoWeb.IssueLive.Show.HelpersTest do
  use ExUnit.Case, async: true

  alias CymphoWeb.IssueLive.Show.Helpers

  test "runtime run ledger exposes prompt context telemetry" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    run = %{
      id: "run-1",
      status: "running",
      agent_id: "agent-1",
      adapter: "process",
      inserted_at: now,
      started_at: now,
      completed_at: nil,
      error_reason: nil,
      continuation_summary: nil,
      log_excerpt: nil,
      workspace_path: "/tmp/work",
      input_tokens: 0,
      output_tokens: 0,
      cost_usd: Decimal.new("0"),
      run_metadata: %{
        "prompt_context" => %{
          "chars" => 12_345,
          "estimated_tokens" => 3_087,
          "sections" => 18,
          "risk" => "large",
          "source" => "agent_prompt"
        },
        "prompt_delivery" => %{
          "role" => "engineer",
          "role_playbook" => true,
          "role_completion_contract" => true,
          "action_contract" => true,
          "custom_overrides" => "present"
        }
      }
    }

    assert [card] = Helpers.runtime_run_ledger([run], [%{id: "agent-1", name: "Agent One"}])
    assert card.agent_name == "Agent One"
    assert card.prompt_chars == 12_345
    assert card.prompt_estimated_tokens == 3_087
    assert card.prompt_sections == 18
    assert card.prompt_risk == "large"
    assert card.prompt_source == "agent_prompt"
    assert card.prompt_role == "engineer"
    assert card.prompt_contract_received? == true
    assert card.prompt_custom_overrides == "present"
  end
end
