defmodule CymphoWeb.ChannelCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a channel.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      require Phoenix.ChannelTest
      import Phoenix.ChannelTest
      import CymphoWeb.ChannelCase
      import Cympho.WaitHelpers

      @endpoint CymphoWeb.Endpoint

      @doc """
      Connects a socket with JWT auth (agent-style).
      """
      def connect_jwt(company_id, agent_id) do
        company =
          Cympho.Repo.get(Cympho.Companies.Company, company_id) ||
            Cympho.Repo.insert!(%Cympho.Companies.Company{
              id: company_id,
              name: "Socket Company #{company_id}",
              slug: "socket-#{String.replace(company_id, "-", "")}"
            })

        agent =
          Cympho.Repo.get(Cympho.Agents.Agent, agent_id) ||
            Cympho.Repo.insert!(%Cympho.Agents.Agent{
              id: agent_id,
              company_id: company.id,
              name: "Socket Agent #{agent_id}",
              role: :engineer,
              status: :running
            })

        issue =
          Cympho.Repo.insert!(%Cympho.Issues.Issue{
            company_id: company.id,
            assignee_id: agent.id,
            title: "Socket auth run",
            description: "Socket auth run",
            status: :in_progress
          })

        run =
          Cympho.Repo.insert!(%Cympho.HeartbeatEngine.Run{
            company_id: company.id,
            agent_id: agent.id,
            issue_id: issue.id,
            status: "running",
            adapter: "process",
            workspace_path: System.tmp_dir!(),
            started_at: DateTime.utc_now() |> DateTime.truncate(:second)
          })

        {:ok, token} =
          Cympho.AgentAuthJWT.generate_token(agent.id, run.id, company.id)

        Phoenix.ChannelTest.connect(CymphoWeb.Socket, %{"token" => token}, connect_info: %{})
      end

      @doc """
      Connects a socket with session auth (browser-style).
      """
      def connect_session(company_id, user_id, session_version \\ 0) do
        Phoenix.ChannelTest.connect(CymphoWeb.Socket, %{},
          connect_info: %{
            session: %{
              "user_id" => user_id,
              "company_id" => company_id,
              "session_version" => session_version
            }
          }
        )
      end
    end
  end

  setup tags do
    Cympho.DataCase.setup_sandbox(tags)
    Cympho.RateLimiting.IpRateLimiter.reset()
    Cympho.RateLimiting.BroadcastDedup.reset()
    :ok
  end
end
