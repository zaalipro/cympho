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
