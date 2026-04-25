defmodule Cympho.Inbox do
  import Ecto.Query, warn: false
  alias Cympho.Repo
  alias Cympho.Inbox.InboxState

  def get_inbox_state(issue_id, agent_id) do
    Repo.get_by(InboxState, issue_id: issue_id, agent_id: agent_id)
  end

  def list_inbox_for_agent(agent_id, opts \\ []) do
    status = Keyword.get(opts, :status)

    query =
      from(s in InboxState,
        where: s.agent_id == ^agent_id,
        order_by: [desc: s.inserted_at]
      )

    query = if status, do: where(query, status: ^status), else: query
    Repo.all(query) |> Repo.preload([:issue])
  end

  def mark_read(issue_id, agent_id) do
    case get_inbox_state(issue_id, agent_id) do
      nil -> {:error, :not_found}
      state -> state |> InboxState.read_changeset() |> Repo.update()
    end
  end

  def dismiss(issue_id, agent_id) do
    case get_inbox_state(issue_id, agent_id) do
      nil -> {:error, :not_found}
      state -> state |> InboxState.dismiss_changeset() |> Repo.update()
    end
  end

  def archive(issue_id, agent_id) do
    case get_inbox_state(issue_id, agent_id) do
      nil -> {:error, :not_found}
      state -> state |> InboxState.archive_changeset() |> Repo.update()
    end
  end

  def restore(issue_id, agent_id) do
    case get_inbox_state(issue_id, agent_id) do
      nil -> {:error, :not_found}
      state -> state |> InboxState.restore_changeset() |> Repo.update()
    end
  end

  def ensure_inbox_entry(issue_id, agent_id) do
    case get_inbox_state(issue_id, agent_id) do
      nil ->
        %InboxState{}
        |> InboxState.changeset(%{issue_id: issue_id, agent_id: agent_id, status: "unread"})
        |> Repo.insert()

      existing ->
        {:ok, existing}
    end
  end
end
