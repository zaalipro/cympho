defmodule CymphoWeb.ExecutionPolicyLiveTest do
  use CymphoWeb.LiveCase, async: true

  alias Cympho.ExecutionPolicies

  test "new policy form starts with a staged governance template", %{conn: conn} do
    {:ok, view, html} = live(conn, "/settings/policies/new")

    assert html =~ ~s(id="execution-policy-form")
    assert html =~ "Default staged execution"
    assert html =~ "require_different_actor"
    assert html =~ "require_human"

    # v7 S10: a deep form page under Review steps; the form is a pair.
    doc = CymphoWeb.R3PageHelpers.main_doc(view)

    CymphoWeb.R3PageHelpers.assert_r3_page(doc,
      page: "policy-form",
      h1: "New review step",
      kind: :deep,
      parent: "Review steps",
      primaries: 1
    )

    assert CymphoWeb.R3PageHelpers.texts(doc, ".crumb [aria-current=page]") == ["New review step"]

    assert CymphoWeb.R3PageHelpers.text(doc, "form#execution-policy-form.fpair .ink .pw") ==
             "Save review step"

    assert CymphoWeb.R3PageHelpers.texts(
             doc,
             "form#execution-policy-form .fp-main > section .card-h h2"
           ) ==
             ["Name", "Stages"]

    assert Floki.find(doc, "form#execution-policy-form .ink a.pd[href='/settings/policies']") !=
             []

    assert length(Floki.find(doc, ".fld-ck input[type=checkbox]")) == 9

    assert [_] =
             Floki.find(
               doc,
               ".ui-advanced-only details#policy-json-preview textarea[name='execution_policy[stage_configs]'][spellcheck=false]"
             )

    refute html =~ "execution-policy-setup-checklist"
    assert Floki.find(doc, ".set-main") == []
  end

  @tag membership_role: "admin"
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

  @tag membership_role: "admin"
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

  @tag membership_role: "admin"
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

  @tag membership_role: "admin"
  test "edit policy form parses updated stage config JSON", %{
    conn: conn,
    current_company: company
  } do
    {:ok, policy} =
      ExecutionPolicies.create_execution_policy(%{
        name: "Original policy",
        company_id: company.id,
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

    # v7 S11: the crumb names the action, the H1 the record; Cancel returns to it.
    doc = CymphoWeb.R3PageHelpers.main_doc(view)

    CymphoWeb.R3PageHelpers.assert_r3_page(doc,
      page: "policy-form",
      h1: "Edit Original policy",
      kind: :deep,
      parent: "Review steps",
      primaries: 1
    )

    assert CymphoWeb.R3PageHelpers.texts(doc, ".crumb [aria-current=page]") == [
             "Edit review step"
           ]

    assert Floki.find(
             doc,
             "form#execution-policy-form .ink a.pd[href='/settings/policies/#{policy.id}']"
           ) !=
             []

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

  @tag membership_role: "admin"
  test "edit policy form saves guided stage builder changes", %{
    conn: conn,
    current_company: company
  } do
    {:ok, policy} =
      ExecutionPolicies.create_execution_policy(%{
        name: "Guided edit policy",
        company_id: company.id,
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
    {:ok, view, html} = live(conn, "/settings/policies")

    assert html =~ ~s(data-testid="policy-command")
    assert html =~ "Create a default execution policy before scaling autonomy"
    # r3 (v7 S9, mockup frame f): the empty list carries the only Add control.
    assert html =~ "No review steps yet"
    assert html =~ "Add one to have an agent or you check work before it is done."

    assert has_element?(
             view,
             "#execution_policies-empty a.pl[href='/settings/policies/new']",
             "Add a review step"
           )

    refute has_element?(view, ".card-h a.pl[href='/settings/policies/new']")
  end

  test "lists review steps as rows in the Review steps band", %{
    conn: conn,
    current_company: company
  } do
    {:ok, policy} =
      ExecutionPolicies.create_execution_policy(%{
        name: "Quick fixes",
        company_id: company.id,
        stage_configs: [%{"type" => "executor", "participant_id" => "engineer"}]
      })

    {:ok, view, _html} = live(conn, "/settings/policies")
    doc = CymphoWeb.R3PageHelpers.main_doc(view)

    CymphoWeb.R3PageHelpers.assert_r3_page(doc,
      page: "settings",
      h1: "Settings",
      kind: :root,
      primaries: 0
    )

    assert CymphoWeb.R3PageHelpers.text(doc, "section[aria-labelledby=po-t] .card-h h2") ==
             "Review steps"

    assert Floki.find(
             doc,
             "section[aria-labelledby=po-t] .card-h a.pl[href='/settings/policies/new']"
           ) !=
             []

    assert [row] = Floki.find(doc, "#execution_policies-#{policy.id}.lrow")

    assert Floki.attribute(Floki.find(row, "a.rt2"), "href") == [
             "/settings/policies/#{policy.id}"
           ]

    assert CymphoWeb.R3PageHelpers.text(row, ".lr-st") == "Review gap"
    assert Floki.find(row, ".lr-acts a.pl[href='/settings/policies/#{policy.id}/edit']") != []

    assert Floki.find(row, ".lr-acts button.pl.warn[phx-click=delete_execution_policy]") != []
    assert Floki.find(doc, ".ui-advanced-only section[data-testid=policy-command]") != []
  end

  test "policy command prioritizes missing participants", %{
    conn: conn,
    current_company: company
  } do
    {:ok, _policy} =
      ExecutionPolicies.create_execution_policy(%{
        name: "Broken handoff",
        company_id: company.id,
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

  test "policy command recognizes governed policies", %{
    conn: conn,
    current_company: company
  } do
    {:ok, _policy} =
      ExecutionPolicies.create_execution_policy(%{
        name: "Owner review pipeline",
        company_id: company.id,
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
    assert html =~ "Human approval"
    assert html =~ "Ready"
  end

  @tag membership_role: "admin"
  test "new policy stamps current company and ignores client company_id", %{
    conn: conn,
    current_company: company
  } do
    unique = System.unique_integer([:positive])

    {:ok, other_company} =
      Cympho.Companies.create_company(%{
        name: "Other Policy Co #{unique}",
        slug: "other-policy-co-#{unique}"
      })

    {:ok, view, _html} = live(conn, "/settings/policies/new")

    result =
      render_submit(view, "save", %{
        "execution_policy" => %{
          "name" => "Stamped policy",
          "company_id" => other_company.id,
          "stage_input_mode" => "json",
          "stage_configs" =>
            Jason.encode!([%{"type" => "executor", "participant_id" => "engineer"}])
        }
      })

    assert {:error, {:live_redirect, %{to: "/settings/policies/" <> id}}} = result
    {:ok, policy} = ExecutionPolicies.get_execution_policy(id)
    assert policy.company_id == company.id
    refute policy.company_id == other_company.id
  end

  test "empty tenant does not inherit another tenant's governed posture", %{conn: conn} do
    unique = System.unique_integer([:positive])

    {:ok, other_company} =
      Cympho.Companies.create_company(%{
        name: "Foreign Policy Co #{unique}",
        slug: "foreign-policy-co-#{unique}"
      })

    {:ok, _policy} =
      ExecutionPolicies.create_execution_policy(%{
        name: "Foreign governed pipeline",
        company_id: other_company.id,
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

    assert html =~ "Create a default execution policy before scaling autonomy"
    refute html =~ "Foreign governed pipeline"
    refute html =~ "Execution policies are ready for autonomous work"
  end

  # v7 S12: the stages read as an r3 step list on a deep page under Review steps.
  test "policy show lists its stages as steps", %{conn: conn, current_company: company} do
    {:ok, policy} =
      ExecutionPolicies.create_execution_policy(%{
        name: "Staged pipeline",
        company_id: company.id,
        stage_configs: [
          %{"type" => "executor", "participant_id" => "engineer"},
          %{"type" => "reviewer", "participant_id" => "", "require_different_actor" => true}
        ]
      })

    {:ok, view, _html} = live(conn, "/settings/policies/#{policy.id}")
    doc = CymphoWeb.R3PageHelpers.main_doc(view)

    CymphoWeb.R3PageHelpers.assert_r3_page(doc,
      page: "policy",
      h1: "Staged pipeline",
      kind: :deep,
      parent: "Review steps",
      primaries: 0
    )

    assert CymphoWeb.R3PageHelpers.text(doc, ".head .chips .chip") == "2 stages"
    assert Floki.find(doc, ".head .chips a.pl[href='/settings/policies/#{policy.id}/edit']") != []
    assert length(Floki.find(doc, "section[aria-labelledby=st-t] .steps .step")) == 2
    assert CymphoWeb.R3PageHelpers.text(doc, ".steps .step:nth-child(2) .nop") == "No participant"

    assert CymphoWeb.R3PageHelpers.text(doc, ".steps .step:nth-child(2) .tag") ==
             "Different actor"
  end

  test "show and edit of a foreign policy redirect with Policy not found", %{conn: conn} do
    unique = System.unique_integer([:positive])

    {:ok, other_company} =
      Cympho.Companies.create_company(%{
        name: "Foreign Show Co #{unique}",
        slug: "foreign-show-co-#{unique}"
      })

    {:ok, policy} =
      ExecutionPolicies.create_execution_policy(%{
        name: "Foreign only",
        company_id: other_company.id,
        stage_configs: [%{"type" => "executor", "participant_id" => "engineer"}]
      })

    assert {:error, {:live_redirect, %{to: "/settings/policies"}}} =
             live(conn, "/settings/policies/#{policy.id}")

    assert {:error, {:live_redirect, %{to: "/settings/policies"}}} =
             live(conn, "/settings/policies/#{policy.id}/edit")

    assert {:ok, ^policy} =
             ExecutionPolicies.get_company_execution_policy(other_company.id, policy.id)
  end

  @tag membership_role: "admin"
  test "delete of a foreign policy id does not remove the other tenant", %{conn: conn} do
    unique = System.unique_integer([:positive])

    {:ok, other_company} =
      Cympho.Companies.create_company(%{
        name: "Foreign Delete Co #{unique}",
        slug: "foreign-delete-co-#{unique}"
      })

    {:ok, policy} =
      ExecutionPolicies.create_execution_policy(%{
        name: "Keep me",
        company_id: other_company.id,
        stage_configs: [%{"type" => "executor", "participant_id" => "engineer"}]
      })

    {:ok, view, _html} = live(conn, "/settings/policies")

    result = render_click(view, "delete_execution_policy", %{"id" => policy.id})

    assert {:error, {:live_redirect, %{to: "/settings/policies"}}} = result

    assert {:ok, kept} =
             ExecutionPolicies.get_company_execution_policy(other_company.id, policy.id)

    assert kept.name == "Keep me"
  end
end
