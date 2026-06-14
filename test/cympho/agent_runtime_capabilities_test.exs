defmodule Cympho.AgentRuntimeCapabilitiesTest do
  use Cympho.DataCase, async: true

  alias Cympho.AgentRuntimeCapabilities

  test "does not treat Agrenting output mode as repo delivery capable" do
    agent = %{
      adapter: :agrenting,
      config: %{
        "agent_did" => "did:example:remote",
        "capability" => "implementation",
        "delivery_mode" => "output"
      }
    }

    refute AgentRuntimeCapabilities.repo_delivery_capable?(agent)
  end

  test "treats Agrenting push mode with a repo-token secret as repo delivery capable" do
    agent = %{
      adapter: :agrenting,
      config: %{
        "agent_did" => "did:example:remote",
        "capability" => "implementation",
        "delivery_mode" => "push"
      }
    }

    assert AgentRuntimeCapabilities.repo_delivery_capable?(agent,
             secret_keys: ["AGRENTING_REPO_ACCESS_TOKEN"]
           )
  end

  test "allows explicit repo capability overrides for custom runtimes" do
    assert AgentRuntimeCapabilities.repo_delivery_capable?(%{
             adapter: :process,
             config: %{"command" => "echo", "repo_capable" => true}
           })

    assert AgentRuntimeCapabilities.repo_delivery_capable?(%{
             adapter: :agrenting,
             config: %{"delivery_mode" => "output", "repo_capable" => true}
           })
  end
end
