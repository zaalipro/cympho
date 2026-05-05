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

      @endpoint CymphoWeb.Endpoint

      @doc """
      Connects a socket with JWT auth (agent-style).
      """
      def connect_jwt(company_id, agent_id) do
        {:ok, token} =
          Cympho.AgentAuthJWT.generate_token(agent_id, "run-#{:rand.uniform(1000)}", company_id)

        Phoenix.ChannelTest.connect(CymphoWeb.Socket, %{"token" => token}, connect_info: %{})
      end

      @doc """
      Connects a socket with session auth (browser-style).
      """
      def connect_session(company_id, user_id) do
        Phoenix.ChannelTest.connect(CymphoWeb.Socket, %{},
          connect_info: %{
            session: %{"user_id" => user_id, "company_id" => company_id}
          })
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
