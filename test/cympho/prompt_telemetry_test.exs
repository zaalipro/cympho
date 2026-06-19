defmodule Cympho.PromptTelemetryTest do
  use Cympho.DataCase, async: true

  alias Cympho.{Agents, Companies, HeartbeatEngine, Issues, PromptTelemetry}

  test "estimate stores counts and hash without storing prompt text" do
    prompt = """
    ## Context
    Secret project notes.

    ## Contract
    Produce evidence.
    """

    telemetry = PromptTelemetry.estimate(prompt)

    assert telemetry["chars"] == String.length(prompt)
    assert telemetry["bytes"] == byte_size(prompt)
    assert telemetry["estimated_tokens"] == div(String.length(prompt) + 3, 4)
    assert telemetry["lines"] == length(String.split(prompt, "\n"))
    assert telemetry["sections"] == 2
    assert telemetry["hash"] =~ "sha256:"
    assert telemetry["risk"] == "normal"
    refute inspect(telemetry) =~ "Secret project notes"
  end

  test "attach_to_run records prompt delivery receipt without storing instruction text" do
    {:ok, company} =
      Companies.create_company(%{
        name: "Prompt Receipt Co #{System.unique_integer([:positive])}",
        slug: "prompt-receipt-#{System.unique_integer([:positive])}"
      })

    {:ok, agent} =
      Agents.create_agent(%{
        name: "Receipt Agent",
        role: "engineer",
        company_id: company.id,
        adapter: :process,
        adapter_type: "process",
        instructions: "Custom secret workflow: notify finance before risky delivery."
      })

    {:ok, issue} =
      Issues.create_issue(%{
        title: "Prompt receipt issue",
        description: "Prove the runtime prompt carries the role contract.",
        company_id: company.id,
        assigned_role: "engineer"
      })

    {:ok, run} =
      HeartbeatEngine.create_run(%{
        company_id: company.id,
        agent_id: agent.id,
        issue_id: issue.id,
        adapter: "process"
      })

    prompt =
      Cympho.AgentPrompt.build(issue, agent.id,
        runtime_context: %Cympho.RuntimeContext{
          run_id: run.id,
          issue_id: issue.id,
          agent_id: agent.id,
          company_id: company.id,
          adapter: :process,
          adapter_config: %{},
          cwd: "/tmp/cympho-work"
        }
      )

    assert :ok = PromptTelemetry.attach_to_run([run_id: run.id], prompt)
    assert {:ok, updated} = HeartbeatEngine.get_run(run.id)

    delivery = updated.run_metadata["prompt_delivery"]
    assert delivery["role"] == "engineer"
    assert delivery["role_playbook"] == true
    assert delivery["role_completion_contract"] == true
    assert delivery["action_contract"] == true
    assert delivery["runtime_context"] == true
    assert delivery["issue_context"] == true
    assert delivery["custom_overrides"] == "present"
    assert delivery["custom_overrides_hash"] =~ "sha256:"
    assert delivery["hash"] =~ "sha256:"

    refute inspect(delivery) =~ "notify finance"
    refute inspect(updated.run_metadata) =~ "Custom secret workflow"
  end

  test "attach_to_run merges prompt context telemetry into run metadata" do
    {:ok, company} =
      Companies.create_company(%{
        name: "Prompt Telemetry Co #{System.unique_integer([:positive])}",
        slug: "prompt-telemetry-#{System.unique_integer([:positive])}"
      })

    {:ok, agent} =
      Agents.create_agent(%{
        name: "Telemetry Agent",
        role: "engineer",
        company_id: company.id,
        adapter: :process,
        adapter_type: "process"
      })

    {:ok, issue} =
      Issues.create_issue(%{
        title: "Prompt telemetry issue",
        description: "Measure prompt size without storing prompt text.",
        company_id: company.id,
        assigned_role: "engineer"
      })

    {:ok, run} =
      HeartbeatEngine.create_run(%{
        company_id: company.id,
        agent_id: agent.id,
        issue_id: issue.id,
        adapter: "process",
        run_metadata: %{"existing" => %{"keep" => true}}
      })

    prompt = "## Work\nDo the private thing."

    assert :ok =
             PromptTelemetry.attach_to_run([run_id: run.id], prompt, %{
               "adapter" => "process"
             })

    assert {:ok, updated} = HeartbeatEngine.get_run(run.id)
    assert updated.run_metadata["existing"]["keep"] == true

    context = updated.run_metadata["prompt_context"]
    assert context["adapter"] == "process"
    assert context["source"] == "agent_prompt"
    assert context["chars"] == String.length(prompt)
    assert context["estimated_tokens"] == div(String.length(prompt) + 3, 4)
    assert context["sections"] == 1
    refute inspect(context) =~ "private thing"

    assert updated.run_metadata["prompt_delivery"]["issue_context"] == false
  end
end
