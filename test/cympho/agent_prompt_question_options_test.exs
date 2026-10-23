defmodule Cympho.AgentPromptQuestionOptionsTest do
  @moduledoc "B3: agents are told they may offer 2–4 short numbered answers with a question."
  use Cympho.DataCase, async: true

  alias Cympho.{AgentPrompt, Companies, Issues}

  test "the action contract and the Ask me first mode describe optional answer options" do
    {:ok, %{agents: [_ceo, _cto, engineer | _], seed_issues: [issue | _]}} =
      Companies.create_autonomous_company(%{
        name: "Question options #{System.unique_integer([:positive])}",
        issue_prefix: "QOPT",
        engineer_count: 1
      })

    {:ok, issue} = Issues.set_work_mode(issue, :ask)
    prompt = AgentPrompt.build(issue, engineer)

    # The shared action contract and the Ask me first contract both name the shape.
    assert length(String.split(prompt, ~s(optionally `options`: 2–4 short answers))) == 3
    assert prompt =~ ~s({"question":"...","options":["...","..."]})
  end
end
