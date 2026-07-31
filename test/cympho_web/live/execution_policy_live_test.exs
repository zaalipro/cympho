defmodule CymphoWeb.ExecutionPolicyLiveTest do
  use CymphoWeb.LiveCase, async: true

  alias Cympho.ExecutionPolicies

  test "new policy form starts with a staged governance template", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/settings/policies/new")

    assert html =~ ~s(id="execution-policy-form")
    assert html =~ "Default staged execution"
    assert html =~ "Governance stage plan"
    assert html =~ "Stage builder"
    assert html =~ "Default governance flow"
    assert html =~ ~s(data-testid="execution-policy-setup-checklist")
    assert html =~ "require_different_actor"
    assert html =~ "require_human"
  end

  test "new policy form saves guided stage builder fields", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/settings/policies/new")

    result =
      view
      |> form("#execution-policy-form",
        execution_policy: %{
          name: "Guided staged execution",
          stage_1_type: "executor",
          stage_1_participant_id: "engineer-1",
          stage_1_require_different_actor: "false",
          stage_1_require_human: "false",
          stage_1_auto_advance: "true",
          stage_2_type: "reviewer",
          stage_2_participant_id: "cto",
          stage_2_require_different_actor: "true",
          stage_2_require_human: "false",
          stage_2_auto_advance: "false",
          stage_3_type: "approver",
          stage_3_participant_id: "ceo",
          stage_3_require_different_actor: "false",
          stage_3_require_human: "true",
          stage_3_auto_advance: "false"
        }
      )
      |> render_submit()

    assert {:error, {:live_redirect, %{to: "/settings/policies/" <> id}}} = result
    {:ok, policy} = ExecutionPolicies.get_execution_policy(id)

    assert policy.stage_configs == [
             %{
               "type" => "executor",
               "participant_id" => "engineer-1",
               "require_different_actor" => false,
               "require_human" => false,
               "auto_advance" => true
             },
             %{
               "type" => "reviewer",
               "participant_id" => "cto",
               "require_different_actor" => true,
               "require_human" => false,
               "auto_advance" => false
             },
             %{
               "type" => "approver",
               "participant_id" => "ceo",
               "require_different_actor" => false,
               "require_human" => true,
               "auto_advance" => false
             }
           ]
  end

  test "new policy form parses stage config JSON before saving", %{conn: conn} do
    stage_configs = [
      %{"type" => "executor", "participant_id" => "engineer"},
      %{"type" => "reviewer", "participant_id" => "cto", "require_different_actor" => true},
      %{"type" => "approver", "participant_id" => "ceo", "require_human" => true}
    ]

    {:ok, view, _html} = live(conn, "/settings/policies/new")

    result =
      render_submit(view, "save", %{
        "execution_policy" => %{
          "name" => "Default staged execution",
          "stage_input_mode" => "json",
          "stage_configs" => Jason.encode!(stage_configs)
        }
      })

    assert {:error, {:live_redirect, %{to: "/settings/policies/" <> id}}} = result
    {:ok, policy} = ExecutionPolicies.get_execution_policy(id)

    assert policy.name == "Default staged execution"

    assert policy.stage_configs == [
             %{
               "type" => "executor",
               "participant_id" => "engineer",
               "require_different_actor" => false,
               "require_human" => false,
               "auto_advance" => false
             },
             %{
               "type" => "reviewer",
               "participant_id" => "cto",
               "require_different_actor" => true,
               "require_human" => false,
               "auto_advance" => false
             },
             %{
               "type" => "approver",
               "participant_id" => "ceo",
               "require_different_actor" => false,
               "require_human" => true,
               "auto_advance" => false
             }
           ]
  end

  test "new policy form keeps invalid JSON editable", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/settings/policies/new")

    html =
      render_submit(view, "save", %{
        "execution_policy" => %{
          "name" => "Broken policy",
          "stage_input_mode" => "json",
          "stage_configs" => "["
        }
      })

    assert html =~ "must be valid JSON"
    assert html =~ ~s(<textarea)
    assert html =~ "["
  end

  test "edit policy form parses updated stage config JSON", %{conn: conn} do
    {:ok, policy} =
      ExecutionPolicies.create_execution_policy(%{
        name: "Original policy",
        stage_configs: [
          %{"type" => "executor", "participant_id" => "engineer"}
        ]
      })

    stage_configs = [
      %{"type" => "executor", "participant_id" => "engineer"},
      %{"type" => "reviewer", "participant_id" => "cto", "require_different_actor" => true}
    ]

    {:ok, view, html} = live(conn, "/settings/policies/#{policy.id}/edit")

    assert html =~ ~s(id="execution-policy-form")
    assert html =~ "Original policy"
    assert html =~ "Governance stage plan"
    assert html =~ "Stage builder"
    assert html =~ ~s(data-testid="execution-policy-setup-checklist")

    result =
      render_submit(view, "save", %{
        "execution_policy" => %{
          "name" => "Reviewed policy",
          "stage_input_mode" => "json",
          "stage_configs" => Jason.encode!(stage_configs)
        }
      })

    assert {:error, {:live_redirect, %{to: edit_redirect_path}}} = result
    assert edit_redirect_path == "/settings/policies/#{policy.id}"
    {:ok, updated_policy} = ExecutionPolicies.get_execution_policy(policy.id)

    assert updated_policy.name == "Reviewed policy"

    assert updated_policy.stage_configs == [
             %{
               "type" => "executor",
               "participant_id" => "engineer",
               "require_different_actor" => false,
               "require_human" => false,
               "auto_advance" => false
             },
             %{
               "type" => "reviewer",
               "participant_id" => "cto",
               "require_different_actor" => true,
               "require_human" => false,
               "auto_advance" => false
             }
           ]
  end

  test "edit policy form saves guided stage builder changes", %{conn: conn} do
    {:ok, policy} =
      ExecutionPolicies.create_execution_policy(%{
        name: "Guided edit policy",
        stage_configs: [
          %{"type" => "executor", "participant_id" => "engineer"},
          %{"type" => "reviewer", "participant_id" => "cto"},
          %{"type" => "approver", "participant_id" => "ceo"}
        ]
      })

    {:ok, view, _html} = live(conn, "/settings/policies/#{policy.id}/edit")

    result =
      view
      |> form("#execution-policy-form",
        execution_policy: %{
          name: "Guided edit policy",
          stage_1_type: "executor",
          stage_1_participant_id: "engineer",
          stage_1_require_different_actor: "false",
          stage_1_require_human: "false",
          stage_1_auto_advance: "true",
          stage_2_type: "reviewer",
          stage_2_participant_id: "qa-lead",
          stage_2_require_different_actor: "true",
          stage_2_require_human: "false",
          stage_2_auto_advance: "false",
          stage_3_type: "approver",
          stage_3_participant_id: "owner",
          stage_3_require_different_actor: "false",
          stage_3_require_human: "true",
          stage_3_auto_advance: "false"
        }
      )
      |> render_submit()

    redirect_path = "/settings/policies/#{policy.id}"
    assert {:error, {:live_redirect, %{to: ^redirect_path}}} = result
    {:ok, updated_policy} = ExecutionPolicies.get_execution_policy(policy.id)

    assert Enum.map(updated_policy.stage_configs, & &1["participant_id"]) == [
             "engineer",
             "qa-lead",
             "owner"
           ]

    assert Enum.map(updated_policy.stage_configs, & &1["auto_advance"]) == [true, false, false]
    assert Enum.at(updated_policy.stage_configs, 1)["require_different_actor"] == true
    assert Enum.at(updated_policy.stage_configs, 2)["require_human"] == true
  end

  test "empty policy library explains the first governance step", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/settings/policies")

    assert html =~ ~s(data-testid="policy-command")
    assert html =~ "Create a default execution policy before scaling autonomy"
    assert html =~ "No governance policies configured yet."
    assert html =~ "Create one so every run has an owner, a reviewer, and an approver."
    assert html =~ "New policy"
  end

  test "policy command prioritizes missing participants", %{conn: conn} do
    {:ok, _policy} =
      ExecutionPolicies.create_execution_policy(%{
        name: "Broken handoff",
        stage_configs: [
          %{"type" => "executor", "participant_id" => "executor"},
          %{"type" => "reviewer", "participant_id" => ""}
        ]
      })

    {:ok, _view, html} = live(conn, "/settings/policies")

    assert html =~ "Assign missing participants in policy stages"
    assert html =~ "Broken handoff"
    assert html =~ "Missing people"
    assert html =~ "1 missing"

    assert html =~
             "Delete Broken handoff? New issues will no longer be able to use this staged execution guardrail."
  end

  test "policy command recognizes governed policies", %{conn: conn} do
    {:ok, _policy} =
      ExecutionPolicies.create_execution_policy(%{
        name: "Owner review pipeline",
        stage_configs: [
          %{"type" => "executor", "participant_id" => "engineer"},
          %{
            "type" => "reviewer",
            "participant_id" => "cto",
            "require_different_actor" => true
          },
          %{"type" => "approver", "participant_id" => "ceo", "require_human" => true}
        ]
      })

    {:ok, _view, html} = live(conn, "/settings/policies")

    assert html =~ "Execution policies are ready for autonomous work"
    assert html =~ "Owner review pipeline"
    assert html =~ "Different actor"
    assert html =~ "Human required"
    assert html =~ "Ready"
  end
end
