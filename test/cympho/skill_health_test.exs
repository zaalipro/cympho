defmodule Cympho.SkillHealthTest do
  use Cympho.DataCase, async: true

  alias Cympho.Companies
  alias Cympho.Skills

  describe "health_summary/2" do
    test "reports empty state when no skills exist" do
      company = create_company("empty")

      assert %{
               level: :empty,
               label: "Not configured",
               metrics: %{total_skills: 0},
               summary: "No skills are configured for this company yet."
             } = Skills.health_summary(company.id, hot_reloader_running?: true)

      assert Skills.health_summary(company.id, hot_reloader_running?: true).next_action == %{
               key: :create_first_skill,
               tone: :neutral,
               label: "Create first skill",
               detail:
                 "Start with one narrow capability, define its manifest, and assign it only where the agent can produce evidence with it.",
               cta: "New skill"
             }
    end

    test "detects invalid manifests, capability gaps, disabled skills, and hot reload gaps" do
      company = create_company("risk")

      {:ok, _invalid} =
        Skills.create_skill(%{
          identifier: "invalid-#{System.unique_integer([:positive])}",
          name: "Invalid Skill",
          manifest: %{"entrypoint" => "Missing.Metadata"},
          enabled: true,
          company_id: company.id
        })

      {:ok, _capability_gap} =
        Skills.create_skill(%{
          identifier: "cap-gap-#{System.unique_integer([:positive])}",
          name: "Capability Gap",
          version: "1.0.0",
          author: "Cympho",
          manifest: valid_manifest("Capability Gap", []),
          enabled: true,
          company_id: company.id
        })

      {:ok, _disabled} =
        Skills.create_skill(%{
          identifier: "disabled-#{System.unique_integer([:positive])}",
          name: "Disabled Skill",
          version: "1.0.0",
          author: "Cympho",
          manifest: valid_manifest("Disabled Skill", ["git"]),
          enabled: false,
          company_id: company.id
        })

      summary = Skills.health_summary(company.id, hot_reloader_running?: false)

      assert summary.level == :critical
      assert summary.metrics.total_skills == 3
      assert summary.metrics.enabled_skills == 2
      assert summary.metrics.invalid_manifest_skills == 1
      assert summary.metrics.capabilityless_enabled_skills == 1
      assert summary.metrics.disabled_skills == 1
      assert summary.metrics.hot_reloader_running? == false
      assert Enum.any?(summary.recommendations, &(&1.label == "Repair manifests"))
      assert Enum.any?(summary.recommendations, &(&1.label == "Declare capabilities"))
      assert Enum.any?(summary.recommendations, &(&1.label == "Check hot reload"))
      assert Enum.any?(summary.recommendations, &(&1.label == "Audit disabled skills"))
      assert summary.next_action.key == :repair_manifests
      assert summary.next_action.cta == "Review manifests"
    end

    test "reports healthy when enabled skills have valid manifests and capabilities" do
      company = create_company("healthy")

      {:ok, _skill} =
        Skills.create_skill(%{
          identifier: "healthy-#{System.unique_integer([:positive])}",
          name: "Healthy Skill",
          version: "1.0.0",
          author: "Cympho",
          manifest: valid_manifest("Healthy Skill", ["git", "file_io"]),
          enabled: true,
          company_id: company.id
        })

      assert %{
               level: :healthy,
               label: "Healthy",
               metrics: %{
                 enabled_skills: 1,
                 invalid_manifest_skills: 0,
                 capabilityless_enabled_skills: 0
               },
               recommendations: []
             } = Skills.health_summary(company.id, hot_reloader_running?: true)

      assert Skills.health_summary(company.id, hot_reloader_running?: true).next_action.key ==
               :review_prompt_fit
    end
  end

  defp create_company(label) do
    unique = System.unique_integer([:positive])

    {:ok, company} =
      Companies.create_company(%{
        name: "Skill #{label} #{unique}",
        slug: "skill-#{label}-#{unique}"
      })

    company
  end

  defp valid_manifest(name, capabilities) do
    %{
      "name" => name,
      "version" => "1.0.0",
      "author" => "Cympho",
      "entrypoint" => "Cympho.Skills.TestEntry",
      "capabilities" => capabilities,
      "dependencies" => %{},
      "permissions" => []
    }
  end
end
