defmodule Cympho.RouterKeywordFloorTest do
  @moduledoc """
  Regression smoke (spec 01, TEST-010) — proves the keyword router
  behaviour is unchanged when `:llm_router_enabled?` is false. This is
  the deterministic floor we promise rollback can fall back to.
  """

  use ExUnit.Case, async: false

  alias Cympho.Orchestrator.Dispatcher.Router
  alias Cympho.Routing

  setup do
    prior = Application.get_env(:cympho, :llm_router_enabled?)
    Application.put_env(:cympho, :llm_router_enabled?, false)

    on_exit(fn ->
      if is_nil(prior),
        do: Application.delete_env(:cympho, :llm_router_enabled?),
        else: Application.put_env(:cympho, :llm_router_enabled?, prior)
    end)

    :ok
  end

  test "Router.infer_role/1 keyword behavior is preserved" do
    assert :ceo == Router.infer_role(%{title: "Strategic funding vision", description: ""})

    assert :cto ==
             Router.infer_role(%{
               title: "Refactor the database architecture",
               description: ""
             })

    assert :designer ==
             Router.infer_role(%{title: "UX research for onboarding", description: ""})

    assert :release_engineer ==
             Router.infer_role(%{title: "Deploy and tag a new release", description: ""})

    assert :researcher ==
             Router.infer_role(%{title: "Research competitor positioning", description: ""})

    assert :content_strategist ==
             Router.infer_role(%{title: "Draft newsletter and social captions", description: ""})

    assert :marketer ==
             Router.infer_role(%{title: "Plan SEO launch campaign", description: ""})

    assert :sales_development ==
             Router.infer_role(%{title: "Build prospect outreach sequence", description: ""})

    assert :customer_support ==
             Router.infer_role(%{title: "Write customer support FAQ", description: ""})

    assert :qa_engineer ==
             Router.infer_role(%{title: "Run regression smoke test plan", description: ""})

    assert :engineer ==
             Router.infer_role(%{title: "Fix the login bug", description: ""})

    assert :engineer == Router.infer_role(%{title: "no keywords here", description: ""})
  end

  test "Router respects assigned business-function roles" do
    assert :marketer ==
             Router.infer_role(%{
               title: "Generic task",
               description: "",
               assigned_role: "marketing"
             })
  end

  test "Routing.classify_role/2 returns :fallback source with keyword role when LLM off" do
    issue = %{
      id: Ecto.UUID.generate(),
      title: "Refactor architecture",
      description: ""
    }

    assert {:ok, :cto, :fallback} = Routing.classify_role(issue)
  end

  test "Routing.classify_and_persist/2 is a no-op when LLM off (does not touch DB)" do
    # We pass a struct that doesn't exist in DB. If the implementation
    # tried to persist, it would error. The :fallback path must skip
    # persistence entirely.
    issue = %Cympho.Issues.Issue{
      id: Ecto.UUID.generate(),
      title: "Implement feature",
      description: "",
      monitor_state: %{}
    }

    assert {:noop, ^issue} = Routing.classify_and_persist(issue)
  end
end
