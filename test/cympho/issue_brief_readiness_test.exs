defmodule Cympho.IssueBriefReadinessTest do
  use Cympho.DataCase, async: true

  alias Cympho.IssueBriefReadiness

  test "scores thin owner briefs as not launch-ready" do
    readiness = IssueBriefReadiness.evaluate(%{"title" => "Thin", "description" => "Do it."})

    assert readiness.status == :thin
    assert readiness.passed_count == 0
    assert readiness.next_prompt =~ "Outcome"
    assert readiness.launch_scaffold =~ "Goal: <the business outcome the owner wants>"

    assert readiness.launch_scaffold =~
             "CEO first output (`[owner_update]`, `[handoff]`, or `[blocked]`):"

    assert readiness.launch_scaffold =~
             "Missing signals: Outcome, Context, Risk/constraint, Done signal, First CEO signal, Evidence."
  end

  test "scores complete owner briefs from atom-keyed issue data" do
    readiness =
      IssueBriefReadiness.evaluate(%{
        title: "Improve onboarding activation",
        description: """
        Goal: improve onboarding activation.
        Context: activation drops after project creation.
        Constraints / risks: must not slow the workspace setup path.
        Definition of done: CEO returns a plan or handoff with acceptance criteria.
        CEO first output (`[owner_update]`, `[handoff]`, or `[blocked]`): hand off execution if needed.
        Evidence to inspect after the run: scoped child issues and verification notes.
        """
      })

    assert readiness.status == :ready
    assert readiness.passed_count == 6
    assert readiness.next_prompt == "All launch signals are present."
    assert readiness.launch_scaffold =~ "Goal: Improve onboarding activation"
    assert readiness.launch_scaffold =~ "Missing signals: none."
  end

  test "keeps almost-complete owner briefs in draft until all launch signals are present" do
    readiness =
      IssueBriefReadiness.evaluate(%{
        title: "Improve onboarding activation",
        description: """
        Goal: improve onboarding activation.
        Context: activation drops after project creation.
        Constraints / risks: must not slow the workspace setup path.
        Definition of done: CEO returns a plan or handoff with acceptance criteria.
        CEO first output (`[owner_update]`, `[handoff]`, or `[blocked]`): hand off execution if needed.
        """
      })

    assert readiness.status == :draft
    assert readiness.passed_count == 5
    assert readiness.next_prompt =~ "Evidence"
    assert readiness.launch_scaffold =~ "Evidence to inspect after the run:"
    assert readiness.launch_scaffold =~ "Missing signals: Evidence."
  end

  test "does not count unfilled launch scaffold placeholders as ready signals" do
    title = "Browser CEO brief repair smoke"

    scaffold =
      IssueBriefReadiness.evaluate(%{
        title: title,
        description: "Do it."
      }).launch_scaffold

    readiness =
      IssueBriefReadiness.evaluate(%{
        title: title,
        description: scaffold
      })

    assert readiness.status == :thin
    assert readiness.passed_count == 1
    assert readiness.next_prompt =~ "Context"

    assert readiness.launch_scaffold =~
             "Missing signals: Context, Risk/constraint, Done signal, First CEO signal, Evidence."
  end

  test "repair scaffold preserves meaningful partial owner brief lines" do
    readiness =
      IssueBriefReadiness.evaluate(%{
        title: "Improve onboarding activation",
        description: """
        Context: activation drops after workspace creation.
        Constraints / risks: must not slow first workspace creation.
        Evidence to inspect after the run: activation funnel and scoped child issues.
        """
      })

    assert readiness.status == :draft
    assert readiness.passed_count == 4
    assert readiness.launch_scaffold =~ "Goal: Improve onboarding activation"
    assert readiness.launch_scaffold =~ "Context: activation drops after workspace creation."

    assert readiness.launch_scaffold =~
             "Constraints / risks: must not slow first workspace creation."

    assert readiness.launch_scaffold =~
             "Evidence to inspect after the run: activation funnel and scoped child issues."

    assert readiness.launch_scaffold =~
             "Definition of done: <owner-visible proof that this request is complete>"

    assert readiness.launch_scaffold =~ "Missing signals: Done signal, First CEO signal."
  end

  test "scores natural owner prose without exact scaffold labels" do
    readiness =
      IssueBriefReadiness.evaluate(%{
        title: "Improve onboarding activation",
        description: """
        Use the AILogic project and onboarding repo as context.
        Do not change billing or spend provider credits.
        Done when the owner can see the queued CEO plan and scoped child issues.
        Hand off execution to the CTO after the CEO sizes the work.
        Evidence should include tests passing and child issue links.
        """
      })

    assert readiness.status == :ready
    assert readiness.passed_count == 6
    assert readiness.next_prompt == "All launch signals are present."
    assert readiness.launch_scaffold =~ "Goal: Improve onboarding activation"
    assert readiness.launch_scaffold =~ "Context: Use the AILogic project"
    assert readiness.launch_scaffold =~ "Constraints / risks: Do not change billing"
    assert readiness.launch_scaffold =~ "Definition of done: Done when the owner"

    assert readiness.launch_scaffold =~
             "CEO first output (`[owner_update]`, `[handoff]`, or `[blocked]`): Hand off"

    assert readiness.launch_scaffold =~
             "Evidence to inspect after the run: Evidence should include"

    assert readiness.launch_scaffold =~ "Missing signals: none."
  end
end
