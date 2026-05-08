defmodule Cympho.InboxTest do
  use Cympho.DataCase, async: true
  alias Cympho.Inbox

  setup do
    {:ok, company} =
      Cympho.Companies.create_company(%{
        name: "Test Co",
        slug: "inbox-test-#{System.unique_integer()}"
      })

    prefix = for _ <- 1..4, into: "", do: <<Enum.random(?A..?Z)>>

    {:ok, project} =
      Cympho.Projects.create_project(%{name: "Proj", prefix: prefix, company_id: company.id})

    {:ok, issue} = Cympho.Issues.create_issue(%{title: "Test Issue", project_id: project.id})

    {:ok, agent} =
      Cympho.Agents.create_agent(%{
        name: "Bot",
        role: "engineer",
        status: "idle",
        company_id: company.id
      })

    {:ok, issue: issue, agent: agent}
  end

  describe "ensure_inbox_entry" do
    test "creates a new inbox entry", %{issue: issue, agent: agent} do
      assert {:ok, state} = Inbox.ensure_inbox_entry(issue.id, agent.id)
      assert state.status == "unread"
    end

    test "returns existing entry if already present", %{issue: issue, agent: agent} do
      {:ok, first} = Inbox.ensure_inbox_entry(issue.id, agent.id)
      {:ok, second} = Inbox.ensure_inbox_entry(issue.id, agent.id)
      assert first.id == second.id
    end
  end

  describe "state transitions" do
    test "mark_read transitions to read", %{issue: issue, agent: agent} do
      {:ok, _} = Inbox.ensure_inbox_entry(issue.id, agent.id)
      {:ok, state} = Inbox.mark_read(issue.id, agent.id)
      assert state.status == "read"
      assert state.read_at != nil
    end

    test "dismiss transitions to dismissed", %{issue: issue, agent: agent} do
      {:ok, _} = Inbox.ensure_inbox_entry(issue.id, agent.id)
      {:ok, state} = Inbox.dismiss(issue.id, agent.id)
      assert state.status == "dismissed"
      assert state.dismissed_at != nil
    end

    test "archive transitions to archived", %{issue: issue, agent: agent} do
      {:ok, _} = Inbox.ensure_inbox_entry(issue.id, agent.id)
      {:ok, state} = Inbox.archive(issue.id, agent.id)
      assert state.status == "archived"
      assert state.archived_at != nil
    end

    test "restore resets to unread", %{issue: issue, agent: agent} do
      {:ok, _} = Inbox.ensure_inbox_entry(issue.id, agent.id)
      {:ok, _} = Inbox.archive(issue.id, agent.id)
      {:ok, state} = Inbox.restore(issue.id, agent.id)
      assert state.status == "unread"
      assert state.dismissed_at == nil
      assert state.archived_at == nil
    end

    test "returns error for non-existent entry" do
      assert {:error, :not_found} = Inbox.mark_read(Ecto.UUID.generate(), Ecto.UUID.generate())
    end
  end

  describe "list_inbox_for_agent" do
    test "lists entries for an agent", %{issue: issue, agent: agent} do
      {:ok, _} = Inbox.ensure_inbox_entry(issue.id, agent.id)
      entries = Inbox.list_inbox_for_agent(agent.id)
      assert length(entries) == 1
    end

    test "filters by status", %{issue: issue, agent: agent} do
      {:ok, _} = Inbox.ensure_inbox_entry(issue.id, agent.id)
      unread = Inbox.list_inbox_for_agent(agent.id, status: "unread")
      assert length(unread) == 1
      archived = Inbox.list_inbox_for_agent(agent.id, status: "archived")
      assert length(archived) == 0
    end
  end

  describe "counts_by_agent_for_company/1" do
    test "returns status counts nested by agent", %{issue: issue, agent: agent} do
      {:ok, _} = Inbox.ensure_inbox_entry(issue.id, agent.id)

      counts = Inbox.counts_by_agent_for_company(agent.company_id)

      assert counts[agent.id]["unread"] == 1
    end
  end
end
