defmodule Cympho.DeliveryBriefReadinessTest do
  use Cympho.DataCase, async: true

  alias Cympho.DeliveryBriefReadiness

  test "scores thin delegated delivery briefs as not ready" do
    readiness =
      DeliveryBriefReadiness.evaluate(%{"title" => "Build it", "description" => "Do it."})

    assert readiness.status == :thin
    assert readiness.passed_count == 0
    assert readiness.next_prompt =~ "Acceptance criteria"
    assert readiness.repair_scaffold =~ "Delivery goal: Build it"
    assert readiness.repair_scaffold =~ "Acceptance criteria: <observable done conditions>"

    assert readiness.repair_scaffold =~
             "Missing delivery signals: Acceptance criteria, Evidence required, Verification required, Definition of done."
  end

  test "scores complete execution briefs as ready" do
    readiness =
      DeliveryBriefReadiness.evaluate(%{
        title: "Implement owner-intake scaffold",
        description: """
        Acceptance criteria:
        - Scaffold button opens the owner brief editor.

        Evidence required:
        - Pull request and focused LiveView test output.

        Verification required:
        - mix test test/cympho_web/live/issue_live_test.exs

        Definition of done:
        - Ready for review after PR and browser smoke are recorded.
        """
      })

    assert readiness.status == :ready
    assert readiness.passed_count == 4
    assert readiness.next_prompt == "All delivery signals are present."
    assert readiness.repair_scaffold =~ "Missing delivery signals: none."
  end

  test "does not count unfilled placeholders as ready signals" do
    readiness =
      DeliveryBriefReadiness.evaluate(%{
        title: "Placeholder brief",
        description: """
        Acceptance criteria: <observable done conditions>
        Evidence required: <PR or work product>
        Verification required: <command>
        Definition of done: <final reviewable state>
        """
      })

    assert readiness.status == :thin
    assert readiness.passed_count == 0
    assert readiness.next_prompt =~ "Acceptance criteria"
  end
end
