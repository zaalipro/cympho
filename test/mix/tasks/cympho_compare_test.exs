defmodule Mix.Tasks.CymphoCompareTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  test "json mode emits decodable JSON without routine app logs" do
    previous_level = Logger.level()
    previous_repo_config = Application.get_env(:cympho, Cympho.Repo)
    parent = self()

    log =
      capture_log(fn ->
        output =
          capture_io(fn ->
            Mix.Task.reenable("app.start")
            Mix.Tasks.Cympho.Compare.run(["--json"])
          end)

        send(parent, {:compare_output, output})
      end)

    assert_receive {:compare_output, output}

    assert log == ""
    assert Logger.level() == previous_level
    assert Application.get_env(:cympho, Cympho.Repo) == previous_repo_config
    assert output |> String.trim_leading() |> String.starts_with?("[")

    rows = Jason.decode!(output)
    assert Enum.any?(rows, &(&1["slug"] == "bring_your_own_agent"))

    assert %{"verdict" => "exceeds", "evidence" => evidence} =
             Enum.find(rows, &(&1["slug"] == "cost_control"))

    assert evidence =~ "owner-visible spend posture"

    assert %{"verdict" => "exceeds", "evidence" => evidence} =
             Enum.find(rows, &(&1["slug"] == "ticket_system"))

    assert evidence =~ "issue-memory handoff packets"

    assert %{"verdict" => "exceeds", "evidence" => evidence} =
             Enum.find(rows, &(&1["slug"] == "governance"))

    assert evidence =~ "governance risk briefs"

    assert %{"verdict" => "exceeds", "evidence" => evidence} =
             Enum.find(rows, &(&1["slug"] == "org_chart"))

    assert evidence =~ "org health diagnostics"

    assert %{"verdict" => "exceeds", "evidence" => evidence} =
             Enum.find(rows, &(&1["slug"] == "routines_schedules"))

    assert evidence =~ "health diagnostics"
    assert evidence =~ "stale runs"

    assert %{"verdict" => "exceeds", "evidence" => evidence} =
             Enum.find(rows, &(&1["slug"] == "workspaces"))

    assert evidence =~ "execution health"
    assert evidence =~ "preview gaps"

    assert %{"verdict" => "exceeds", "evidence" => evidence} =
             Enum.find(rows, &(&1["slug"] == "plugins"))

    assert evidence =~ "plugin health"
    assert evidence =~ "capability gaps"

    assert %{"verdict" => "exceeds", "evidence" => evidence} =
             Enum.find(rows, &(&1["slug"] == "goal_alignment"))

    assert evidence =~ "alignment coverage"

    assert %{"verdict" => "exceeds", "evidence" => evidence} =
             Enum.find(rows, &(&1["slug"] == "company_portability"))

    assert evidence =~ "non-secret secret manifest"
    assert evidence =~ "post-import restore checklist"

    assert %{"verdict" => "exceeds", "evidence" => evidence} =
             Enum.find(rows, &(&1["slug"] == "company_blueprints"))

    assert evidence =~ "17 executable"
    assert evidence =~ "exceed Paperclip"
    assert evidence =~ "executable company blueprints"
    assert evidence =~ "onboarding plus CLI"

    assert %{"verdict" => "exceeds", "evidence" => evidence} =
             Enum.find(rows, &(&1["slug"] == "secrets"))

    assert evidence =~ "rotation posture"
    refute output =~ "[debug]"
  end
end
