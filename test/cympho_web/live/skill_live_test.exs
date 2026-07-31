defmodule CymphoWeb.SkillLiveTest do
  use CymphoWeb.LiveCase, async: true

  alias Cympho.Companies
  alias Cympho.Projects
  alias Cympho.Skills
  alias Cympho.Skills.Manifest

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

      assert has_element?(view, "[data-testid='skill-health']")
      assert has_element?(view, "[data-testid='skill-next-action']")
      assert html =~ "Skill Health"
      # "Cap gaps" and "Next operator move" were unexplained jargon.
      assert html =~ "Capability gaps"
      assert html =~ "Auto-reload"
      assert html =~ "Declare capabilities"
      assert html =~ "Do this next"
      refute html =~ "Next operator move"
      assert html =~ "Current Company Skill"
      refute html =~ "Other Company Skill"
    end
  end

  describe "SkillLive.New" do
    test "renders the capability launch form", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/skills/new")

      assert html =~ "Skill launch plan"
      assert html =~ "Capability brief"
      assert html =~ "Runtime manifest"
      assert html =~ "Project scope"
      assert html =~ "Setup checklist"
      assert html =~ "Creates a valid manifest"
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

      assert html =~ "Skill capability plan"
      assert html =~ "Runtime manifest"
      assert html =~ "Maintenance checklist"

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
