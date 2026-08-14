defmodule Cympho.WorkspaceTest do
  use ExUnit.Case, async: false

  alias Cympho.Workspace

  describe "workspace_path/1" do
    test "generates path from binary issue id" do
      path = Workspace.workspace_path("abc-123")
      assert path =~ "issue-abc-123"
    end

    test "generates path from issue struct" do
      path = Workspace.workspace_path(%{id: "xyz-456"})
      assert path =~ "issue-xyz-456"
    end
  end

  describe "write_prompt_file/2" do
    test "writes prompt to workspace path" do
      tmp_dir = Path.join(Workspace.workspace_root(), "test_#{:rand.uniform(99999)}")
      File.mkdir_p!(tmp_dir)

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      :ok = Workspace.write_prompt_file(tmp_dir, "# Test Prompt\n\nHello world")
      assert File.read!(Path.join(tmp_dir, "PROMPT.md")) =~ "Hello world"
    end
  end

  describe "remove_workspace/1" do
    test "removes workspace directory" do
      tmp_dir = Path.join(Workspace.workspace_root(), "test_remove_#{:rand.uniform(99999)}")
      File.mkdir_p!(tmp_dir)
      File.write!(Path.join(tmp_dir, "test.txt"), "content")

      assert File.dir?(tmp_dir)
      :ok = Workspace.remove_workspace(tmp_dir)
      refute File.dir?(tmp_dir)
    end

    test "rejects path outside workspace root" do
      result = Workspace.remove_workspace("/etc/passwd")
      assert result == {:error, :path_outside_workspace}
    end
  end

  describe "repository_fingerprint/1" do
    test "normalizes equivalent HTTPS and SSH repository URLs" do
      assert {:ok, https_fingerprint} =
               Workspace.repository_fingerprint("https://github.com/Example/project.git/")

      assert {:ok, scp_fingerprint} =
               Workspace.repository_fingerprint("git@github.com:Example/project.git")

      assert {:ok, ssh_fingerprint} =
               Workspace.repository_fingerprint("ssh://git@github.com/Example/project.git")

      assert https_fingerprint == scp_fingerprint
      assert https_fingerprint == ssh_fingerprint
    end

    test "preserves non-git SSH usernames in repository identity" do
      assert {:ok, alice_fingerprint} =
               Workspace.repository_fingerprint("alice@git.example.com:team/project.git")

      assert {:ok, alice_uri_fingerprint} =
               Workspace.repository_fingerprint("ssh://alice@git.example.com/team/project.git")

      assert {:ok, bob_fingerprint} =
               Workspace.repository_fingerprint("bob@git.example.com:team/project.git")

      assert {:ok, conventional_git_fingerprint} =
               Workspace.repository_fingerprint("git@git.example.com:team/project.git")

      assert {:ok, https_fingerprint} =
               Workspace.repository_fingerprint("https://git.example.com/team/project.git")

      assert alice_fingerprint == alice_uri_fingerprint
      refute alice_fingerprint == bob_fingerprint
      refute alice_fingerprint == https_fingerprint
      assert conventional_git_fingerprint == https_fingerprint
    end

    test "rejects secret-bearing or ambiguous remote URLs" do
      assert {:error, :invalid_repo_url} =
               Workspace.repository_fingerprint("https://token@github.com/example/project.git")

      assert {:error, :invalid_repo_url} =
               Workspace.repository_fingerprint(
                 "https://github.com/example/project.git?token=secret"
               )

      assert {:error, :invalid_repo_url} =
               Workspace.repository_fingerprint("https://github.com/example/project.git#branch")
    end
  end

  describe "safe_host_cwd?/1" do
    test "accepts expanded absolute workspace paths" do
      assert Workspace.safe_host_cwd?("/tmp/cympho/workspaces")
    end

    test "rejects blank, relative, parent, and system paths" do
      refute Workspace.safe_host_cwd?("")
      refute Workspace.safe_host_cwd?("   ")
      refute Workspace.safe_host_cwd?("relative/path")
      refute Workspace.safe_host_cwd?("/tmp/foo/../etc")
      refute Workspace.safe_host_cwd?("/")
      refute Workspace.safe_host_cwd?("/etc")
      refute Workspace.safe_host_cwd?("/usr/bin")
      refute Workspace.safe_host_cwd?("/bin")
      refute Workspace.safe_host_cwd?("/sbin")
      refute Workspace.safe_host_cwd?("/var/tmp")
      refute Workspace.safe_host_cwd?("/System/Library")
      refute Workspace.safe_host_cwd?("/private/etc/passwd")
    end
  end

  describe "workspace update tenancy" do
    test "update changeset does not cast company_id or project_id" do
      company_id = Ecto.UUID.generate()
      project_id = Ecto.UUID.generate()

      pw_changeset =
        Cympho.Workspaces.ProjectWorkspace.update_changeset(
          %Cympho.Workspaces.ProjectWorkspace{company_id: company_id, project_id: project_id},
          %{company_id: Ecto.UUID.generate(), project_id: Ecto.UUID.generate(), name: "Renamed"}
        )

      ew_changeset =
        Cympho.Workspaces.ExecutionWorkspace.update_changeset(
          %Cympho.Workspaces.ExecutionWorkspace{company_id: company_id, project_id: project_id},
          %{company_id: Ecto.UUID.generate(), project_id: Ecto.UUID.generate(), status: "closed"}
        )

      refute Ecto.Changeset.changed?(pw_changeset, :company_id)
      refute Ecto.Changeset.changed?(pw_changeset, :project_id)
      refute Ecto.Changeset.changed?(ew_changeset, :company_id)
      refute Ecto.Changeset.changed?(ew_changeset, :project_id)
    end

    test "create and update reject unsafe cwd" do
      attrs = %{
        name: "Unsafe",
        company_id: Ecto.UUID.generate(),
        project_id: Ecto.UUID.generate(),
        project_workspace_id: Ecto.UUID.generate(),
        cwd: "/etc"
      }

      pw =
        Cympho.Workspaces.ProjectWorkspace.changeset(%Cympho.Workspaces.ProjectWorkspace{}, attrs)

      ew =
        Cympho.Workspaces.ExecutionWorkspace.changeset(
          %Cympho.Workspaces.ExecutionWorkspace{},
          attrs
        )

      refute pw.valid?
      refute ew.valid?
      assert {"is not a safe workspace path", _} = Keyword.get(pw.errors, :cwd)
      assert {"is not a safe workspace path", _} = Keyword.get(ew.errors, :cwd)
    end
  end
end

defmodule Cympho.Workspace.RepoUrlTest do
  use Cympho.DataCase, async: false

  alias Cympho.Projects
  alias Cympho.Workspace

  # Projects now require a company; create a throwaway one per call so the
  # existing fixtures stay self-contained.
  defp create_project_with_company(attrs) do
    {:ok, company} =
      Cympho.Companies.create_company(%{
        name: "Fixture Co",
        slug: "fixture-co-#{System.unique_integer([:positive])}"
      })

    attrs |> Map.put_new(:company_id, company.id) |> Projects.create_project()
  end

  describe "get_repo_url/1" do
    test "returns the project's canonical repo_url" do
      {:ok, project} =
        create_project_with_company(%{
          name: "Canonical Repo Project",
          prefix: "CR",
          repo_url: "https://github.com/example/canonical.git"
        })

      assert {:ok, "https://github.com/example/canonical.git"} =
               Workspace.get_repo_url(project.id)
    end

    test "prefers the canonical repo_url over the legacy settings value" do
      {:ok, project} =
        create_project_with_company(%{
          name: "Canonical Repo Project",
          prefix: "CP",
          repo_url: "https://github.com/example/canonical.git",
          settings: %{"repo_url" => "https://github.com/example/legacy.git"}
        })

      assert {:ok, "https://github.com/example/canonical.git"} =
               Workspace.get_repo_url(project.id)
    end

    test "returns repo_url from project settings" do
      {:ok, project} =
        create_project_with_company(%{
          name: "Test Project",
          prefix: "TP",
          settings: %{"repo_url" => "https://github.com/example/repo.git"}
        })

      assert {:ok, "https://github.com/example/repo.git"} = Workspace.get_repo_url(project.id)
    end

    test "falls back to app env when project settings has no repo_url" do
      {:ok, project} =
        create_project_with_company(%{
          name: "No Repo Project",
          prefix: "NR"
        })

      original = Application.get_env(:cympho, :workspace_default_repo)

      Application.put_env(
        :cympho,
        :workspace_default_repo,
        "https://fallback.example.com/repo.git"
      )

      on_exit(fn ->
        if original do
          Application.put_env(:cympho, :workspace_default_repo, original)
        else
          Application.delete_env(:cympho, :workspace_default_repo)
        end
      end)

      assert {:ok, "https://fallback.example.com/repo.git"} = Workspace.get_repo_url(project.id)
    end

    test "falls back to app env when project not found" do
      original = Application.get_env(:cympho, :workspace_default_repo)

      Application.put_env(
        :cympho,
        :workspace_default_repo,
        "https://fallback.example.com/repo.git"
      )

      on_exit(fn ->
        if original do
          Application.put_env(:cympho, :workspace_default_repo, original)
        else
          Application.delete_env(:cympho, :workspace_default_repo)
        end
      end)

      fake_id = Ecto.UUID.generate()
      assert {:ok, "https://fallback.example.com/repo.git"} = Workspace.get_repo_url(fake_id)
    end

    test "returns error when no repo configured anywhere" do
      {:ok, project} =
        create_project_with_company(%{
          name: "Empty Settings Project",
          prefix: "ES"
        })

      original = Application.get_env(:cympho, :workspace_default_repo)
      Application.delete_env(:cympho, :workspace_default_repo)

      on_exit(fn ->
        if original do
          Application.put_env(:cympho, :workspace_default_repo, original)
        end
      end)

      assert {:error, :no_repo_configured} = Workspace.get_repo_url(project.id)
    end

    test "ignores empty string repo_url in project settings" do
      {:ok, project} =
        create_project_with_company(%{
          name: "Empty Repo Project",
          prefix: "ER",
          settings: %{"repo_url" => ""}
        })

      original = Application.get_env(:cympho, :workspace_default_repo)
      Application.delete_env(:cympho, :workspace_default_repo)

      on_exit(fn ->
        if original do
          Application.put_env(:cympho, :workspace_default_repo, original)
        end
      end)

      assert {:error, :no_repo_configured} = Workspace.get_repo_url(project.id)
    end

    test "ignores non-string repo_url in project settings" do
      {:ok, project} =
        create_project_with_company(%{
          name: "Bad Repo Project",
          prefix: "BR",
          settings: %{"repo_url" => 12345}
        })

      original = Application.get_env(:cympho, :workspace_default_repo)
      Application.delete_env(:cympho, :workspace_default_repo)

      on_exit(fn ->
        if original do
          Application.put_env(:cympho, :workspace_default_repo, original)
        end
      end)

      assert {:error, :no_repo_configured} = Workspace.get_repo_url(project.id)
    end
  end

  describe "create_for_issue/1" do
    test "clones the repo onto a branch named from the issue identifier and title" do
      repo_dir = local_git_repo!()

      {:ok, project} =
        create_project_with_company(%{
          name: "Branch Project",
          prefix: "BP",
          settings: %{"repo_url" => repo_dir}
        })

      issue = %{
        id: Ecto.UUID.generate(),
        identifier: "CYM-88",
        title: "Improve PR docs",
        project_id: project.id
      }

      on_exit(fn ->
        File.rm_rf!(repo_dir)
        File.rm_rf!(Workspace.workspace_path(issue))
      end)

      assert {:ok, path} = Workspace.create_for_issue(issue)
      assert File.dir?(path)

      assert {"CYM-88/improve-pr-docs\n", 0} =
               System.cmd("git", ["branch", "--show-current"], cd: path)
    end
  end

  describe "ensure_for_issue/1" do
    test "clones a configured repository when the issue path is absent" do
      repo_dir = local_git_repo!()
      issue = repo_issue!(repo_dir, "CYM-91", "Provision missing workspace", "PM")
      path = Workspace.workspace_path(issue)

      on_exit(fn ->
        File.rm_rf!(repo_dir)
        File.rm_rf!(path)
      end)

      refute File.exists?(path)
      assert {:ok, ^path} = Workspace.ensure_for_issue(issue)
      assert File.read!(Path.join(path, "README.md")) == "# Test\n"
      assert_git_workspace(path)
    end

    test "replaces the known empty CLI control-directory scaffold with a clone" do
      repo_dir = local_git_repo!()
      issue = repo_issue!(repo_dir, "CYM-92", "Recover CLI scaffold", "RS")
      path = Workspace.workspace_path(issue)

      for dirname <- [".git", ".agents", ".codex"] do
        File.mkdir_p!(Path.join(path, dirname))
      end

      on_exit(fn ->
        File.rm_rf!(repo_dir)
        File.rm_rf!(path)
      end)

      assert {:ok, ^path} = Workspace.ensure_for_issue(issue)
      assert File.read!(Path.join(path, "README.md")) == "# Test\n"
      refute File.exists?(Path.join(path, ".agents"))
      refute File.exists?(Path.join(path, ".codex"))
      assert_git_workspace(path)
    end

    test "preserves an arbitrary non-empty non-Git workspace" do
      repo_dir = local_git_repo!()
      issue = repo_issue!(repo_dir, "CYM-93", "Preserve local files", "PL")
      path = Workspace.workspace_path(issue)
      important_path = Path.join(path, "important.txt")

      File.mkdir_p!(path)
      File.write!(important_path, "do not overwrite")

      on_exit(fn ->
        File.rm_rf!(repo_dir)
        File.rm_rf!(path)
      end)

      assert {:error, {:workspace_not_git_repo, ^path}} = Workspace.ensure_for_issue(issue)
      assert File.read!(important_path) == "do not overwrite"
      refute File.exists?(Path.join(path, "README.md"))
    end

    test "reuses an existing Git workspace without resetting its files" do
      repo_dir = local_git_repo!()
      issue = repo_issue!(repo_dir, "CYM-94", "Reuse checkout", "RC")
      path = Workspace.workspace_path(issue)
      marker_path = Path.join(path, "local-change.txt")

      on_exit(fn ->
        File.rm_rf!(repo_dir)
        File.rm_rf!(path)
      end)

      assert {:ok, ^path} = Workspace.ensure_for_issue(issue)
      File.write!(marker_path, "keep me")

      assert {:ok, ^path} = Workspace.ensure_for_issue(issue)
      assert File.read!(marker_path) == "keep me"
    end
  end

  defp repo_issue!(repo_dir, identifier, title, prefix) do
    {:ok, project} =
      create_project_with_company(%{
        name: "Repo Project #{identifier}",
        prefix: prefix,
        settings: %{"repo_url" => repo_dir}
      })

    %{
      id: Ecto.UUID.generate(),
      identifier: identifier,
      title: title,
      project_id: project.id
    }
  end

  defp assert_git_workspace(path) do
    assert {"true\n", 0} =
             System.cmd("git", ["-C", path, "rev-parse", "--is-inside-work-tree"])
  end

  defp local_git_repo! do
    repo_dir = Path.join(System.tmp_dir!(), "cympho_repo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo_dir)

    assert {_output, 0} = System.cmd("git", ["init", "--quiet"], cd: repo_dir)

    assert {_output, 0} =
             System.cmd("git", ["config", "user.email", "test@example.com"], cd: repo_dir)

    assert {_output, 0} = System.cmd("git", ["config", "user.name", "Cympho Test"], cd: repo_dir)

    File.write!(Path.join(repo_dir, "README.md"), "# Test\n")

    assert {_output, 0} = System.cmd("git", ["add", "README.md"], cd: repo_dir)
    assert {_output, 0} = System.cmd("git", ["commit", "--quiet", "-m", "initial"], cd: repo_dir)

    repo_dir
  end
end
