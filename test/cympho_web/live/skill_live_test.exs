defmodule CymphoWeb.SkillLiveTest do
  use CymphoWeb.LiveCase, async: true

  alias Cympho.Companies
  alias Cympho.Projects
  alias Cympho.Skills
  alias Cympho.Skills.Manifest

  import CymphoWeb.R3PageHelpers

  describe "SkillLive.Index" do
    test "renders an actionable empty state before skills are configured", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/skills")

      assert html =~ ~s(data-testid="skills-empty")
      assert html =~ "No reusable skills configured yet"
      assert html =~ "Add one skill and assign it to the agents that need it."
      assert html =~ "New skill"
      # The health block said "no skills" twice more and added a third CTA; the
      # empty state's second destination went with it.
      refute html =~ ~s(data-testid="skill-health")
      refute html =~ "Runtime checklist"
      refute html =~ "No skills found"

      # r3 (v7 H3): a root page under Team; the empty state sits in the list band.
      doc = main_doc(html)
      assert_r3_page(doc, page: "skills", h1: "Skills", kind: :root, primaries: 0)
      assert Floki.attribute(doc, ".ctx-end a.pl", "href") == ["/skills/new"]
      assert [_] = Floki.find(doc, ~s(#skill-list [data-testid="skills-empty"].gl-sec))
    end

    test "lists current-company skills and shows skill health diagnostics", %{
      conn: conn,
      current_company: company
    } do
      {:ok, _current_skill} =
        Skills.create_skill(%{
          identifier: "current-skill-#{System.unique_integer([:positive])}",
          name: "Current Company Skill",
          version: "1.0.0",
          author: "Cympho",
          manifest: valid_manifest("Current Company Skill", []),
          enabled: true,
          company_id: company.id
        })

      other_company = create_company("other")

      {:ok, _other_skill} =
        Skills.create_skill(%{
          identifier: "other-skill-#{System.unique_integer([:positive])}",
          name: "Other Company Skill",
          version: "1.0.0",
          author: "Cympho",
          manifest: valid_manifest("Other Company Skill", ["git"]),
          enabled: true,
          company_id: other_company.id
        })

      {:ok, view, html} = live(conn, "/skills")

      assert has_element?(view, "[data-testid='skill-health'].ui-advanced-only")
      assert has_element?(view, "[data-testid='skill-health'] [data-testid='skill-next-action']")
      assert html =~ "Skill health"
      # "Cap gaps" and "Next operator move" were unexplained jargon.
      assert html =~ "Capability gaps"
      assert html =~ "Auto-reload"
      assert html =~ "Declare capabilities"
      assert html =~ "Do this next"
      refute html =~ "Next operator move"
      assert html =~ "Current Company Skill"
      refute html =~ "Other Company Skill"
    end

    test "rows link to the skill and carry its actions", %{conn: conn, current_company: company} do
      {:ok, skill} =
        Skills.create_skill(%{
          identifier: "row-skill-#{System.unique_integer([:positive])}",
          name: "Row Skill",
          version: "1.2.0",
          author: "Cympho",
          manifest: valid_manifest("Row Skill", ["triage"]),
          enabled: false,
          company_id: company.id
        })

      {:ok, view, _html} = live(conn, "/skills")
      doc = main_doc(view)
      row = ~s(#skill-list .lrow[id="skill-#{skill.id}"])

      assert Floki.attribute(doc, "#{row} a.rt2", "href") == ["/skills/#{skill.id}"]
      assert text(doc, "#{row} .rm") == "#{skill.identifier} · v1.2.0 · Cympho"
      assert text(doc, "#{row} .lr-tr .tag") == "Off"
      assert text(doc, ~s(#{row} .lr-acts button.pl[phx-click="toggle_skill"])) == "Turn on"
      assert Floki.attribute(doc, "#{row} .lr-acts a.pl", "href") == ["/skills/#{skill.id}/edit"]

      assert Floki.attribute(
               doc,
               ~s(#{row} .lr-acts button.pl.warn[phx-click="delete"]),
               "data-confirm"
             ) ==
               ["Delete this skill?"]

      view |> element(~s(#{row} button[phx-click="toggle_skill"])) |> render_click()
      assert {:ok, %{enabled: true}} = Skills.get_company_skill(company.id, skill.id)
      assert text(main_doc(view), ".flash-line .flash-msg") == "Skill enabled"
    end

    # v7 hire r2 (Argon IMP-HIRE-R2-1): a one-option Company select is noise.
    test "the company filter shows only when there is another company to pick", %{
      conn: conn,
      current_company: company
    } do
      {:ok, view, _html} = live(conn, "/skills")
      refute has_element?(view, "#skill-company-filter")

      other_company = create_company("second")

      {:ok, _membership} =
        Companies.create_membership(%{
          user_id: Plug.Conn.get_session(conn, :user_id),
          company_id: other_company.id,
          role: "member"
        })

      {:ok, _skill} =
        Skills.create_skill(%{
          identifier: "second-skill-#{System.unique_integer([:positive])}",
          name: "Second Company Skill",
          version: "1.0.0",
          manifest: valid_manifest("Second Company Skill", []),
          enabled: true,
          company_id: other_company.id
        })

      {:ok, view, html} = live(conn, "/skills")

      assert Floki.attribute(
               main_doc(view),
               ~s(#skill-company-filter select[name="company_id"] option),
               "value"
             )
             |> Enum.sort() == Enum.sort([company.id, other_company.id])

      refute html =~ "Second Company Skill"

      assert view
             |> form("#skill-company-filter", %{company_id: other_company.id})
             |> render_change() =~ "Second Company Skill"
    end
  end

  describe "SkillLive.Show" do
    @tag membership_role: "admin"
    test "is a deep page under Skills with its actions in the head and Delete last", %{
      conn: conn,
      current_company: company
    } do
      {:ok, skill} =
        Skills.create_skill(%{
          identifier: "show-skill-#{System.unique_integer([:positive])}",
          name: "Shown Skill",
          description: "Audit a repository.",
          version: "1.0.0",
          author: "Cympho",
          manifest: valid_manifest("Shown Skill", ["repo_audit"]),
          enabled: true,
          company_id: company.id
        })

      {:ok, view, _html} = live(conn, "/skills/#{skill.id}")
      doc = main_doc(view)

      assert_r3_page(doc,
        page: "skill",
        h1: "Shown Skill",
        kind: :deep,
        parent: "Skills",
        primaries: 0
      )

      assert text(doc, ~s(.head .chips button.pl[phx-click="toggle_skill"])) == "Turn off"
      assert Floki.attribute(doc, ".head .chips a.pl", "href") == ["/skills/#{skill.id}/edit"]
      assert Floki.find(doc, ".head .chip") == []
      assert text(doc, ".sk-desc") == "Audit a repository."
      assert text(doc, ".sk-caps .tag") == "repo_audit"
      assert [_] = Floki.find(doc, ".ui-advanced-only details#skill-manifest pre")
      assert text(doc, ".aside .kv") =~ skill.identifier

      assert Floki.attribute(
               doc,
               ~s(.tray > .card:last-child button.pl.warn[phx-click="delete"]),
               "data-confirm"
             ) ==
               ["Delete this skill?"]

      view |> element(~s(.head button[phx-click="toggle_skill"])) |> render_click()
      assert {:ok, %{enabled: false}} = Skills.get_company_skill(company.id, skill.id)
      assert [_] = Floki.find(main_doc(view), ".head .chips .tag")

      assert {:error, {:live_redirect, %{to: "/skills"}}} =
               view |> element(~s(button[phx-click="delete"])) |> render_click()

      assert {:error, :not_found} = Skills.get_company_skill(company.id, skill.id)
    end
  end

  describe "SkillLive.New" do
    test "renders the capability launch form", %{conn: conn} do
      {:ok, view, html} = live(conn, "/skills/new")

      # r3 (v7 H4): three field cards beside the ink card; the checklist went.
      doc = main_doc(view)

      assert_r3_page(doc,
        page: "skill-form",
        h1: "New skill",
        kind: :deep,
        parent: "Skills",
        primaries: 1
      )

      assert texts(doc, "#skill-form .fp-main .card-h .h2") == [
               "Skill",
               "How agents call it",
               "Scope"
             ]

      assert html =~ "Project scope"
      assert text(doc, "#skill-form .ink .conseq") == "Agents can use it once it is on."
      assert text(doc, "#skill-form .ink .pw[type=submit]") == "Create skill"
      assert Floki.attribute(doc, "#skill-form .ink a.pd", "href") == ["/skills"]
      refute html =~ "Setup checklist"
    end

    test "creates a skill with a valid manifest and project scope", %{
      conn: conn,
      current_company: company
    } do
      {:ok, project} = create_project(company, "Skill Ops")
      identifier = "repo-auditor-#{System.unique_integer([:positive])}"
      {:ok, view, _html} = live(conn, "/skills/new")

      result =
        view
        |> form("form[phx-submit=save]",
          skill: %{
            name: "Repository Auditor",
            identifier: identifier,
            description: "Inspect a repository and return risks with file evidence.",
            version: "1.2.0",
            author: "Cympho Labs",
            entrypoint: "Cympho.Skills.RepositoryAuditor",
            capabilities: "repo_audit, evidence_summary",
            project_id: project.id,
            enabled: "true"
          }
        )
        |> render_submit()

      assert {:error, {:live_redirect, %{to: "/skills/" <> _}}} = result

      assert {:ok, skill} = Skills.get_skill_by_identifier(identifier, company.id)
      assert skill.project_id == project.id
      assert skill.enabled == true
      assert skill.manifest["name"] == "Repository Auditor"
      assert skill.manifest["version"] == "1.2.0"
      assert skill.manifest["author"] == "Cympho Labs"
      assert skill.manifest["entrypoint"] == "Cympho.Skills.RepositoryAuditor"
      assert skill.manifest["capabilities"] == ["repo_audit", "evidence_summary"]
      assert {:ok, %Manifest{}} = Manifest.validate(skill.manifest)
    end

    test "ignores a client-supplied company_id and saves into the current company", %{
      conn: conn,
      current_company: company
    } do
      other_company = create_company("forged-create")
      identifier = "forged-create-#{System.unique_integer([:positive])}"
      {:ok, view, _html} = live(conn, "/skills/new")

      render_hook(view, "save", %{
        "skill" => %{
          "name" => "Forged Create",
          "identifier" => identifier,
          "company_id" => other_company.id
        }
      })

      assert {:ok, skill} = Skills.get_skill_by_identifier(identifier, company.id)
      assert skill.company_id == company.id
      assert {:error, :not_found} = Skills.get_skill_by_identifier(identifier, other_company.id)
    end

    test "rejects a project from another company", %{conn: conn, current_company: company} do
      other_company = create_company("foreign-project")
      {:ok, foreign_project} = create_project(other_company, "Foreign Project")
      identifier = "foreign-project-#{System.unique_integer([:positive])}"
      {:ok, view, _html} = live(conn, "/skills/new")

      render_hook(view, "save", %{
        "skill" => %{
          "name" => "Foreign Project Skill",
          "identifier" => identifier,
          "project_id" => foreign_project.id
        }
      })

      flash = :sys.get_state(view.pid).socket.assigns.flash
      assert Phoenix.Flash.get(flash, :error) == "Choose a project from this company."
      assert {:error, :not_found} = Skills.get_skill_by_identifier(identifier, company.id)
    end
  end

  describe "SkillLive.Show manifest gap" do
    test "a skill whose manifest fails validation says so in its head", %{
      conn: conn,
      current_company: company
    } do
      {:ok, skill} =
        Skills.create_skill(%{
          identifier: "gap-skill-#{System.unique_integer([:positive])}",
          name: "Gap Skill",
          version: "1.0.0",
          manifest: %{"name" => "Gap Skill"},
          enabled: true,
          company_id: company.id
        })

      {:ok, view, _html} = live(conn, "/skills/#{skill.id}")

      assert text(main_doc(view), ".head .chip") == "Manifest gap"
    end
  end

  describe "SkillLive.Edit" do
    test "renders manifest controls and updates skill manifest", %{
      conn: conn,
      current_company: company
    } do
      {:ok, project} = create_project(company, "Skill Edit")

      {:ok, skill} =
        Skills.create_skill(%{
          identifier: "editable-skill-#{System.unique_integer([:positive])}",
          name: "Editable Skill",
          version: "1.0.0",
          author: "Cympho",
          manifest: valid_manifest("Editable Skill", ["old_capability"]),
          enabled: true,
          company_id: company.id
        })

      {:ok, view, html} = live(conn, "/skills/#{skill.id}/edit")

      doc = main_doc(html)

      assert_r3_page(doc,
        page: "skill-form",
        h1: "Edit Editable Skill",
        kind: :deep,
        parent: "Skills",
        primaries: 1
      )

      assert texts(doc, "#skill-form .fp-main .card-h .h2") == [
               "Skill",
               "How agents call it",
               "Scope"
             ]

      assert text(doc, "#skill-form .ink .pw[type=submit]") == "Save skill"
      assert Floki.attribute(doc, "#skill-form .ink a.pd", "href") == ["/skills/#{skill.id}"]
      refute html =~ "Maintenance checklist"

      result =
        view
        |> form("form[phx-submit=save]",
          skill: %{
            name: "Edited Skill",
            identifier: skill.identifier,
            description: "Updated usage brief.",
            version: "2.0.0",
            author: "Cympho Labs",
            entrypoint: "Cympho.Skills.EditedSkill",
            capabilities: "new_capability, review_packet",
            project_id: project.id,
            enabled: "false"
          }
        )
        |> render_submit()

      assert {:error, {:live_redirect, %{to: "/skills/" <> _}}} = result

      assert {:ok, updated} = Skills.get_company_skill(company.id, skill.id)
      assert updated.name == "Edited Skill"
      assert updated.project_id == project.id
      assert updated.enabled == false
      assert updated.manifest["name"] == "Edited Skill"
      assert updated.manifest["version"] == "2.0.0"
      assert updated.manifest["entrypoint"] == "Cympho.Skills.EditedSkill"
      assert updated.manifest["capabilities"] == ["new_capability", "review_packet"]
      assert {:ok, %Manifest{}} = Manifest.validate(updated.manifest)
    end

    test "cannot move a skill into another company via a forged company_id", %{
      conn: conn,
      current_company: company
    } do
      other_company = create_company("forged-edit")

      {:ok, skill} =
        Skills.create_skill(%{
          identifier: "forged-edit-#{System.unique_integer([:positive])}",
          name: "Forged Edit",
          version: "1.0.0",
          author: "Cympho",
          manifest: valid_manifest("Forged Edit", []),
          enabled: true,
          company_id: company.id
        })

      {:ok, view, _html} = live(conn, "/skills/#{skill.id}/edit")

      render_hook(view, "save", %{
        "skill" => %{
          "name" => "Moved Skill",
          "identifier" => skill.identifier,
          "company_id" => other_company.id
        }
      })

      assert {:ok, updated} = Skills.get_company_skill(company.id, skill.id)
      assert updated.name == "Moved Skill"
      assert updated.company_id == company.id
      assert {:error, :not_found} = Skills.get_company_skill(other_company.id, skill.id)
    end
  end

  defp create_company(label) do
    unique = System.unique_integer([:positive])

    {:ok, company} =
      Companies.create_company(%{
        name: "Skill Live #{label} #{unique}",
        slug: "skill-live-#{label}-#{unique}"
      })

    company
  end

  defp create_project(company, name) do
    unique = System.unique_integer([:positive])

    Projects.create_project(%{
      name: name,
      prefix: "S#{alpha_suffix(unique)}",
      company_id: company.id
    })
  end

  defp alpha_suffix(number), do: alpha_suffix(number, "")

  defp alpha_suffix(0, ""), do: "A"
  defp alpha_suffix(0, acc), do: String.slice(acc, 0, 9)

  defp alpha_suffix(number, acc) do
    alpha_suffix(div(number, 26), <<?A + rem(number, 26)>> <> acc)
  end

  defp valid_manifest(name, capabilities) do
    %{
      "name" => name,
      "version" => "1.0.0",
      "author" => "Cympho",
      "entrypoint" => "Cympho.Skills.LiveTestEntry",
      "capabilities" => capabilities,
      "dependencies" => %{},
      "permissions" => []
    }
  end
end
