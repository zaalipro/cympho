defmodule CymphoWeb.Plugs.AgentAuthTest do
  use CymphoWeb.ConnCase, async: true

  alias Cympho.Agents
  alias Cympho.Authentication
  alias Cympho.Companies
  alias Cympho.HeartbeatEngine
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.Issues.Issue
  alias Cympho.Repo
  alias CymphoWeb.Plugs.AgentAuth

  setup do
    unique = System.unique_integer([:positive])

    {:ok, company} =
      Companies.create_company(%{
        name: "Agent Auth #{unique}",
        slug: "agent-auth-#{unique}"
      })

    {:ok, agent} =
      Agents.create_agent(%{
        company_id: company.id,
        name: "Auth Agent #{unique}",
        role: :engineer,
        status: :idle
      })

    {:ok, {api_key, plain_text_key}} =
      Authentication.create_agent_api_key(agent.id, "Auth test")

    %{agent: agent, api_key: api_key, company: company, plain_text_key: plain_text_key}
  end

  describe "API-key authentication" do
    test "rejects paused, pending-approval, and terminated agent state", %{
      agent: agent,
      plain_text_key: plain_text_key
    } do
      blocked_states = [
        %{status: :paused, governance_status: "active"},
        %{status: :pending_approval, governance_status: "active"},
        %{status: :terminated, governance_status: "active"},
        %{status: :idle, governance_status: "paused"},
        %{status: :idle, governance_status: "pending_approval"},
        %{status: :idle, governance_status: "terminated"}
      ]

      Enum.each(blocked_states, fn attrs ->
        {:ok, _updated} = agent |> Ecto.Changeset.change(attrs) |> Repo.update()

        conn =
          build_conn()
          |> put_req_header("x-api-key", plain_text_key)
          |> AgentAuth.call([])

        assert conn.halted
        assert conn.status == 401
        assert {:error, :invalid_api_key} = Authentication.validate_api_key(plain_text_key)
      end)
    end
  end

  describe "run JWT authentication" do
    test "assigns the exact active run bound to the agent and company", %{
      conn: conn,
      agent: agent,
      company: company
    } do
      run = insert_run(agent, company)
      token = token_for(agent.id, run.id, company.id)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> AgentAuth.call([])

      refute conn.halted
      assert conn.assigns.current_agent.id == agent.id
      assert conn.assigns.run_id == run.id
      assert conn.assigns.auth_method == :jwt
    end

    test "rejects missing, terminal, wrong-agent, and cross-company runs", %{
      conn: conn,
      agent: agent,
      company: company
    } do
      other_agent = insert_agent(company, "Other auth agent")
      other_company = insert_company("Other auth company")

      running = insert_run(agent, company)
      terminal = insert_run(agent, company, "completed")
      other_agent_run = insert_run(other_agent, company)

      invalid_tokens = [
        token_for(agent.id, Ecto.UUID.generate(), company.id),
        token_for(agent.id, terminal.id, company.id),
        token_for(agent.id, other_agent_run.id, company.id),
        token_for(agent.id, running.id, other_company.id)
      ]

      Enum.each(invalid_tokens, fn token ->
        rejected =
          conn
          |> recycle()
          |> put_req_header("authorization", "Bearer #{token}")
          |> AgentAuth.call([])

        assert rejected.halted
        assert rejected.status == 401
      end)
    end

    test "rejects paused, pending-approval, and terminated agents even with a running run", %{
      conn: conn,
      agent: agent,
      company: company
    } do
      run = insert_run(agent, company)
      token = token_for(agent.id, run.id, company.id)

      blocked_states = [
        %{status: :paused, governance_status: "active"},
        %{status: :pending_approval, governance_status: "active"},
        %{status: :terminated, governance_status: "active"},
        %{status: :idle, governance_status: "paused"},
        %{status: :idle, governance_status: "pending_approval"},
        %{status: :idle, governance_status: "terminated"}
      ]

      Enum.each(blocked_states, fn attrs ->
        {:ok, _updated} =
          agent
          |> Ecto.Changeset.change(attrs)
          |> Repo.update()

        rejected =
          conn
          |> recycle()
          |> put_req_header("authorization", "Bearer #{token}")
          |> AgentAuth.call([])

        assert rejected.halted
        assert rejected.status == 401
      end)
    end

    test "pausing blocks fresh authentication without blocking internal run finalization", %{
      conn: conn,
      agent: agent,
      company: company
    } do
      run = insert_run(agent, company)
      token = token_for(agent.id, run.id, company.id)

      {:ok, _paused} =
        agent
        |> Ecto.Changeset.change(%{status: :paused, governance_status: "paused"})
        |> Repo.update()

      rejected =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> AgentAuth.call([])

      assert rejected.halted
      assert rejected.status == 401

      assert {:ok, completed} =
               HeartbeatEngine.complete_run(run, %{continuation_summary: "Finished before pause"})

      assert completed.status == "completed"
    end
  end

  defp insert_company(label) do
    unique = System.unique_integer([:positive])

    {:ok, company} =
      Companies.create_company(%{
        name: "#{label} #{unique}",
        slug: "other-agent-auth-#{unique}"
      })

    company
  end

  defp insert_agent(company, label) do
    unique = System.unique_integer([:positive])

    {:ok, agent} =
      Agents.create_agent(%{
        company_id: company.id,
        name: "#{label} #{unique}",
        role: :engineer,
        status: :idle
      })

    agent
  end

  defp insert_run(agent, company, status \\ "running") do
    issue =
      Repo.insert!(%Issue{
        company_id: company.id,
        assignee_id: agent.id,
        title: "Auth run #{System.unique_integer([:positive])}",
        description: "Auth run",
        status: :in_progress
      })

    Repo.insert!(%Run{
      company_id: company.id,
      agent_id: agent.id,
      issue_id: issue.id,
      status: status,
      adapter: "process",
      workspace_path: System.tmp_dir!(),
      started_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
  end

  defp token_for(agent_id, run_id, company_id) do
    {:ok, token} = Cympho.AgentAuthJWT.generate_token(agent_id, run_id, company_id)
    token
  end
end
