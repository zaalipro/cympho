defmodule Cympho.Companies.PackageMergeTest do
  @moduledoc """
  Merge writers for applying a portable package to an existing company.
  """

  use Cympho.DataCase, async: true

  alias Cympho.Agents.Agent
  alias Cympho.Authentication
  alias Cympho.Companies
  alias Cympho.Companies.PackageMerge
  alias Cympho.Companies.PortablePackage
  alias Cympho.Goals.Goal
  alias Cympho.Labels.Label
  alias Cympho.Projects.Project

  setup do
    unique = System.unique_integer([:positive])

    {:ok, company} =
      Companies.create_company(%{
        name: "Merge Target #{unique}",
        slug: "merge-target-#{unique}",
        issue_prefix: "MT"
      })

    {:ok, user} =
      Authentication.register_user(%{
        email: "merge-#{unique}@example.test",
        name: "Merge Operator",
        password: "password123"
      })

    %{company: company, user: user, unique: unique}
  end

  defp package(overrides \\ %{}) do
    Map.merge(
      %{
        "version" => 1,
        "company" => %{"name" => "Standard Package", "slug" => "standard-package"},
        "users" => [],
        "memberships" => [],
        "projects" => [
          %{"id" => "project-1", "name" => "Platform", "prefix" => "PLAT"}
        ],
        "labels" => [
          %{"id" => "label-1", "name" => "bug", "color" => "#FF0000"},
          %{"id" => "label-2", "name" => "chore", "color" => "#00FF00"}
        ],
        "goals" => [
          %{"id" => "goal-1", "title" => "Ship v1", "project_id" => "project-1"},
          %{"id" => "goal-2", "title" => "Ship v2", "parent_id" => "goal-1"}
        ],
        "agents" => [
          %{
            "id" => "agent-1",
            "name" => "Ada",
            "role" => "engineer",
            "config" => %{},
            "project_id" => "project-1",
            "heartbeat_config" => %{"enabled" => true, "interval_seconds" => 60}
          },
          %{"id" => "agent-2", "name" => "Grace", "role" => "cto", "parent_id" => "agent-1"}
        ],
        "issues" => [],
        "secret_manifest" => []
      },
      overrides
    )
  end

  defp counts(company_id) do
    %{
      labels: Repo.aggregate(from(l in Label, where: l.company_id == ^company_id), :count, :id),
      projects:
        Repo.aggregate(from(p in Project, where: p.company_id == ^company_id), :count, :id),
      goals: Repo.aggregate(from(g in Goal, where: g.company_id == ^company_id), :count, :id),
      agents: Repo.aggregate(from(a in Agent, where: a.company_id == ^company_id), :count, :id)
    }
  end

  describe "preview/3" do
    test "plans a clean merge without writing anything", %{company: company} do
      before = counts(company.id)

      assert {:ok, plan} = PackageMerge.preview(package(), company.id)

      assert counts(company.id) == before
      assert plan.target_company.id == company.id
      assert plan.collision == :skip
      assert plan.totals.create == 7
      assert plan.totals.skip == 0
      assert plan.totals.replace == 0
      assert plan.totals.rename == 0
    end

    test "reports collections it will not merge instead of silently dropping them", %{
      company: company
    } do
      assert {:ok, plan} = PackageMerge.preview(package(), company.id)

      unsupported = Enum.map(plan.unsupported, & &1.collection)
      assert :users in unsupported
      assert :memberships in unsupported
      assert :issues in unsupported
      assert :secret_manifest in unsupported

      assert Enum.all?(plan.unsupported, &(is_binary(&1.reason) and &1.reason != ""))
    end

    test "detects collisions against records already in the company", %{company: company} do
      {:ok, _label} = Cympho.Labels.create_label(%{name: "bug", company_id: company.id})

      assert {:ok, plan} = PackageMerge.preview(package(), company.id, collision: :skip)

      labels = Enum.find(plan.collections, &(&1.collection == :labels))
      assert labels.skip == 1
      assert labels.create == 1
      assert [%{key: "bug", action: :skip}] = labels.conflicts
    end

    test "honours selective includes", %{company: company} do
      assert {:ok, plan} = PackageMerge.preview(package(), company.id, includes: [:labels])

      labels = Enum.find(plan.collections, &(&1.collection == :labels))
      agents = Enum.find(plan.collections, &(&1.collection == :agents))

      assert labels.create == 2
      assert agents.create == 0
    end

    test "rejects an unsupported collision mode", %{company: company} do
      assert {:error, {:unsupported_collision_mode, :merge_everything}} =
               PackageMerge.preview(package(), company.id, collision: :merge_everything)
    end

    test "rejects an unknown company", %{} do
      assert {:error, :company_not_found} =
               PackageMerge.preview(package(), Ecto.UUID.generate())
    end

    test "a structurally invalid package never reaches a writer", %{company: company} do
      assert {:error, %{errors: errors}} =
               PackageMerge.preview(%{"version" => 99, "company" => %{}}, company.id)

      assert is_list(errors)
      assert errors != []
    end
  end

  describe "apply/3 with :skip" do
    test "creates everything when there are no collisions", %{company: company} do
      assert {:ok, result} = PackageMerge.apply(package(), company.id)

      assert counts(company.id) == %{labels: 2, projects: 1, goals: 2, agents: 2}
      assert map_size(result.id_maps.labels) == 2
      assert map_size(result.id_maps.agents) == 2
    end

    test "keeps the existing record and remaps references to it", %{company: company} do
      {:ok, existing} =
        Cympho.Projects.create_project(%{
          company_id: company.id,
          name: "Existing Platform",
          prefix: "PLAT"
        })

      assert {:ok, result} = PackageMerge.apply(package(), company.id, collision: :skip)

      assert counts(company.id).projects == 1
      assert result.id_maps.projects["project-1"] == existing.id

      # The goal from the package points at the pre-existing project, not a copy.
      goal = Repo.get!(Goal, result.id_maps.goals["goal-1"])
      assert goal.project_id == existing.id

      # Skipped records keep their own attributes.
      assert Repo.get!(Project, existing.id).name == "Existing Platform"
    end

    test "matches natural keys case-insensitively", %{company: company} do
      {:ok, _label} = Cympho.Labels.create_label(%{name: "BUG", company_id: company.id})

      assert {:ok, _result} = PackageMerge.apply(package(), company.id, collision: :skip)
      assert counts(company.id).labels == 2
    end
  end

  describe "apply/3 with :replace" do
    test "overwrites the existing record from the package", %{company: company} do
      {:ok, existing} =
        Cympho.Labels.create_label(%{name: "bug", color: "#111111", company_id: company.id})

      assert {:ok, result} = PackageMerge.apply(package(), company.id, collision: :replace)

      assert counts(company.id).labels == 2
      assert result.id_maps.labels["label-1"] == existing.id
      assert Repo.get!(Label, existing.id).color == "#FF0000"
    end

    test "warns that records will be overwritten", %{company: company} do
      {:ok, _label} = Cympho.Labels.create_label(%{name: "bug", company_id: company.id})

      assert {:ok, plan} = PackageMerge.preview(package(), company.id, collision: :replace)
      assert Enum.any?(plan.warnings, &(&1.code == :records_replaced))
    end
  end

  describe "apply/3 with :rename" do
    test "creates a copy under a de-duplicated key", %{company: company} do
      {:ok, existing} =
        Cympho.Labels.create_label(%{name: "bug", color: "#111111", company_id: company.id})

      assert {:ok, result} = PackageMerge.apply(package(), company.id, collision: :rename)

      assert counts(company.id).labels == 3
      refute result.id_maps.labels["label-1"] == existing.id
      assert Repo.get!(Label, result.id_maps.labels["label-1"]).name == "bug-copy"
      assert Repo.get!(Label, existing.id).color == "#111111"
    end

    test "uppercases a renamed project prefix", %{company: company} do
      {:ok, _existing} =
        Cympho.Projects.create_project(%{
          company_id: company.id,
          name: "Existing Platform",
          prefix: "PLAT"
        })

      assert {:ok, result} = PackageMerge.apply(package(), company.id, collision: :rename)

      renamed = Repo.get!(Project, result.id_maps.projects["project-1"])
      # Prefixes must stay 2-10 uppercase letters, so the copy gets a letter suffix.
      assert renamed.prefix == "PLATA"
    end
  end

  describe "apply/3 with :fail" do
    test "aborts before any write when a collision exists", %{company: company} do
      {:ok, _label} = Cympho.Labels.create_label(%{name: "bug", company_id: company.id})
      before = counts(company.id)

      assert {:error, {:collision, conflicts}} =
               PackageMerge.apply(package(), company.id, collision: :fail)

      assert counts(company.id) == before
      assert [%{collection: :labels, key: "bug"}] = conflicts
    end

    test "proceeds when nothing collides", %{company: company} do
      assert {:ok, _result} = PackageMerge.apply(package(), company.id, collision: :fail)
      assert counts(company.id).labels == 2
    end
  end

  describe "safety" do
    test "merged agents land paused with heartbeat timers disabled", %{company: company} do
      assert {:ok, result} = PackageMerge.apply(package(), company.id)

      agent = Repo.get!(Agent, result.id_maps.agents["agent-1"])
      assert agent.status == :paused
      assert agent.heartbeat_config["enabled"] == false
      assert agent.pause_reason =~ "merge"
    end

    test "replacing an agent also leaves it paused", %{company: company} do
      {:ok, existing} =
        Cympho.Agents.create_agent(%{
          name: "Ada",
          role: :engineer,
          company_id: company.id,
          status: :idle
        })

      assert {:ok, result} = PackageMerge.apply(package(), company.id, collision: :replace)

      assert result.id_maps.agents["agent-1"] == existing.id
      assert Repo.get!(Agent, existing.id).status == :paused
    end

    test "redacted secret placeholders are never persisted as values", %{company: company} do
      package =
        package(%{
          "agents" => [
            %{
              "id" => "agent-1",
              "name" => "Ada",
              "role" => "engineer",
              "config" => %{"api_key" => "***REDACTED***", "model" => "sonnet"}
            }
          ]
        })

      assert {:ok, result} = PackageMerge.apply(package, company.id)

      agent = Repo.get!(Agent, result.id_maps.agents["agent-1"])
      refute Map.has_key?(agent.config, "api_key")
      assert agent.config["model"] == "sonnet"
    end

    test "records land in the target company, never the package's own", %{company: company} do
      assert {:ok, result} = PackageMerge.apply(package(), company.id)

      for {_source, id} <- result.id_maps.agents do
        assert Repo.get!(Agent, id).company_id == company.id
      end

      for {_source, id} <- result.id_maps.labels do
        assert Repo.get!(Label, id).company_id == company.id
      end
    end

    test "parent links resolve inside the merged set", %{company: company} do
      assert {:ok, result} = PackageMerge.apply(package(), company.id)

      child_goal = Repo.get!(Goal, result.id_maps.goals["goal-2"])
      assert child_goal.parent_id == result.id_maps.goals["goal-1"]

      child_agent = Repo.get!(Agent, result.id_maps.agents["agent-2"])
      assert child_agent.parent_id == result.id_maps.agents["agent-1"]
    end
  end

  describe "PortablePackage facade" do
    test "merge_preview/3 accepts the same sources as import", %{company: company} do
      json = Jason.encode!(package())

      assert {:ok, plan} = PortablePackage.merge_preview(json, company.id)
      assert plan.totals.create == 7
    end

    test "merge/3 applies through the facade", %{company: company} do
      assert {:ok, result} = PortablePackage.merge(package(), company.id, collision: :skip)
      assert map_size(result.id_maps.projects) == 1
    end

    test "collision_modes/0 advertises the merge writers" do
      modes = PortablePackage.collision_modes()
      assert :skip in modes
      assert :replace in modes
      assert :rename in modes
    end
  end
end
