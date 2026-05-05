defmodule Cympho.Agents.InstructionFiles do
  @moduledoc """
  Context for managing per-agent instructions files.

  The entry file (AGENTS.md) lives on `Agent.instructions`; this context
  manages every other file. Callers should treat the two as a unified set —
  `list_for_agent/1` returns the entry plus all extras, sorted with the entry
  first.
  """

  import Ecto.Query

  alias Cympho.Repo
  alias Cympho.Agents.{Agent, InstructionFile}

  @entry_filename "AGENTS.md"

  def entry_filename, do: @entry_filename

  def entry?(filename), do: filename == @entry_filename

  @doc """
  All instruction files for the agent: entry first, extras in alphabetical
  order. Each item is `{filename, content}`.
  """
  def list_for_agent(%Agent{} = agent) do
    extras =
      from(f in InstructionFile,
        where: f.agent_id == ^agent.id,
        order_by: [asc: f.filename],
        select: {f.filename, f.content}
      )
      |> Repo.all()

    [{@entry_filename, agent.instructions || ""} | extras]
  end

  @doc """
  Returns the content of one file. `nil` if the file doesn't exist.
  """
  def get_content(%Agent{} = agent, @entry_filename), do: agent.instructions || ""

  def get_content(%Agent{} = agent, filename) do
    Repo.one(
      from(f in InstructionFile,
        where: f.agent_id == ^agent.id and f.filename == ^filename,
        select: f.content
      )
    )
  end

  @doc """
  Returns true if the file exists for the agent (entry is always considered
  to exist).
  """
  def exists?(_agent, @entry_filename), do: true

  def exists?(%Agent{} = agent, filename) do
    Repo.exists?(
      from(f in InstructionFile, where: f.agent_id == ^agent.id and f.filename == ^filename)
    )
  end

  @doc """
  Creates a new (non-entry) instruction file with empty content. Returns
  `{:error, :reserved_filename}` for the entry name and `{:error, :exists}`
  if a file with that name already exists.
  """
  def create(agent, filename, content \\ "")

  def create(%Agent{} = _agent, @entry_filename, _content), do: {:error, :reserved_filename}

  def create(%Agent{} = agent, filename, content) do
    %InstructionFile{}
    |> InstructionFile.changeset(%{
      agent_id: agent.id,
      filename: filename,
      content: content
    })
    |> Repo.insert()
  end

  @doc """
  Upserts a file's content. The entry file routes to `Agent.instructions`.
  """
  def upsert_content(%Agent{} = agent, @entry_filename, content) do
    Cympho.Agents.update_agent(agent, %{"instructions" => content})
  end

  def upsert_content(%Agent{} = agent, filename, content) do
    case Repo.get_by(InstructionFile, agent_id: agent.id, filename: filename) do
      nil ->
        create(agent, filename, content)

      %InstructionFile{} = existing ->
        existing
        |> InstructionFile.changeset(%{content: content})
        |> Repo.update()
    end
  end

  @doc """
  Deletes a non-entry file. The entry file cannot be deleted.
  """
  def delete(_agent, @entry_filename), do: {:error, :cannot_delete_entry}

  def delete(%Agent{} = agent, filename) do
    case Repo.get_by(InstructionFile, agent_id: agent.id, filename: filename) do
      nil -> {:error, :not_found}
      %InstructionFile{} = file -> Repo.delete(file)
    end
  end
end
