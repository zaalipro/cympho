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
end

defmodule Cympho.Workspace.RepoUrlTest do
  use Cympho.DataCase, async: false

  alias Cympho.Projects
  alias Cympho.Workspace

  describe "get_repo_url/1" do
    test "returns repo_url from project settings" do
      {:ok, project} =
        Projects.create_project(%{
          name: "Test Project",
          prefix: "TP",
          settings: %{"repo_url" => "https://github.com/example/repo.git"}
        })

      assert {:ok, "https://github.com/example/repo.git"} = Workspace.get_repo_url(project.id)
    end

    test "falls back to app env when project settings has no repo_url" do
      {:ok, project} =
        Projects.create_project(%{
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
        Projects.create_project(%{
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
        Projects.create_project(%{
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
        Projects.create_project(%{
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
        Projects.create_project(%{
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
