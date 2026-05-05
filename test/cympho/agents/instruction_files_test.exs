defmodule Cympho.Agents.InstructionFilesTest do
  use Cympho.DataCase, async: true

  alias Cympho.Agents
  alias Cympho.Agents.InstructionFiles

  setup do
    {:ok, agent} =
      Agents.create_agent(%{
        name: "Test Agent",
        role: :engineer,
        instructions: "Entry file content"
      })

    %{agent: agent}
  end

  describe "list_for_agent/1" do
    test "returns the entry file first, then extras alphabetically", %{agent: agent} do
      {:ok, _} = InstructionFiles.create(agent, "z-style.md", "z content")
      {:ok, _} = InstructionFiles.create(agent, "a-style.md", "a content")

      result = InstructionFiles.list_for_agent(agent)

      filenames = Enum.map(result, fn {filename, _} -> filename end)
      assert filenames == [InstructionFiles.entry_filename(), "a-style.md", "z-style.md"]
    end

    test "entry file content comes from agent.instructions", %{agent: agent} do
      [{first_filename, first_content} | _] = InstructionFiles.list_for_agent(agent)
      assert first_filename == InstructionFiles.entry_filename()
      assert first_content == "Entry file content"
    end

    test "entry shows empty string when agent.instructions is nil", %{agent: agent} do
      {:ok, agent} = Agents.update_agent(agent, %{instructions: nil})
      [{_, content} | _] = InstructionFiles.list_for_agent(agent)
      assert content == ""
    end
  end

  describe "create/3" do
    test "creates a non-entry file", %{agent: agent} do
      assert {:ok, file} = InstructionFiles.create(agent, "rules.md", "Be nice.")
      assert file.filename == "rules.md"
      assert file.content == "Be nice."
      assert file.agent_id == agent.id
    end

    test "rejects the entry filename", %{agent: agent} do
      assert {:error, :reserved_filename} =
               InstructionFiles.create(agent, InstructionFiles.entry_filename(), "x")
    end

    test "rejects duplicate filename for the same agent", %{agent: agent} do
      {:ok, _} = InstructionFiles.create(agent, "rules.md", "v1")
      assert {:error, %Ecto.Changeset{}} = InstructionFiles.create(agent, "rules.md", "v2")
    end
  end

  describe "upsert_content/3" do
    test "updates an existing file's content", %{agent: agent} do
      {:ok, _} = InstructionFiles.create(agent, "rules.md", "v1")
      assert {:ok, _} = InstructionFiles.upsert_content(agent, "rules.md", "v2")
      assert InstructionFiles.get_content(agent, "rules.md") == "v2"
    end

    test "creates the file if missing", %{agent: agent} do
      assert {:ok, _} = InstructionFiles.upsert_content(agent, "new.md", "fresh")
      assert InstructionFiles.get_content(agent, "new.md") == "fresh"
    end

    test "entry filename routes to agent.instructions", %{agent: agent} do
      assert {:ok, updated_agent} =
               InstructionFiles.upsert_content(
                 agent,
                 InstructionFiles.entry_filename(),
                 "new entry"
               )

      assert updated_agent.instructions == "new entry"
      # Verify reading back via list_for_agent uses the new value
      [{_, content} | _] = InstructionFiles.list_for_agent(updated_agent)
      assert content == "new entry"
    end
  end

  describe "delete/2" do
    test "deletes a non-entry file", %{agent: agent} do
      {:ok, _} = InstructionFiles.create(agent, "rules.md", "x")
      assert {:ok, _} = InstructionFiles.delete(agent, "rules.md")
      refute InstructionFiles.exists?(agent, "rules.md")
    end

    test "rejects deleting the entry file", %{agent: agent} do
      assert {:error, :cannot_delete_entry} =
               InstructionFiles.delete(agent, InstructionFiles.entry_filename())
    end

    test "returns :not_found for unknown filename", %{agent: agent} do
      assert {:error, :not_found} = InstructionFiles.delete(agent, "nope.md")
    end
  end

  describe "exists?/2" do
    test "entry filename always exists", %{agent: agent} do
      assert InstructionFiles.exists?(agent, InstructionFiles.entry_filename())
    end

    test "returns true for created file", %{agent: agent} do
      {:ok, _} = InstructionFiles.create(agent, "rules.md", "x")
      assert InstructionFiles.exists?(agent, "rules.md")
    end

    test "returns false for unknown filename", %{agent: agent} do
      refute InstructionFiles.exists?(agent, "nope.md")
    end
  end
end
