defmodule Cympho.Smoke.LLMotionsTest do
  use Cympho.DataCase, async: false

  alias Cympho.{
    AgentRuntimeCapabilities,
    Companies,
    Issues,
    RuntimePreflight,
    Secrets,
    Workspaces
  }

  alias Cympho.Smoke.LLMotions

  setup do
    original_key = Application.get_env(:cympho, :encryption_key)
    Application.put_env(:cympho, :encryption_key, String.duplicate("s", 32))

    on_exit(fn ->
      if original_key do
        Application.put_env(:cympho, :encryption_key, original_key)
      else
        Application.delete_env(:cympho, :encryption_key)
      end
    end)
  end

  test "setup creates a focused smoke company without leaking the provider key" do
    unique = System.unique_integer([:positive])

    assert {:ok, report} =
             LLMotions.setup(
               company_name: "LLMotions Smoke Test #{unique}",
               issue_prefix: "LST",
               api_key: "llmotions-secret-value",
               model: "gemini-3.5-flash-low"
             )

    assert report.endpoint == "https://cli.llmotions.com/v1"
    assert report.model == "gemini-3.5-flash-low"
    assert report.secret_status == :created
    refute report.text =~ "llmotions-secret-value"
    assert report.text =~ "LLMotions smoke company ready"
    assert report.text =~ "Focused runtime command:"
    assert report.text =~ "CYMPHO_DISPATCH_ONLY_ISSUE_ID=#{report.issue.id}"
    assert report.text =~ "Workspace:"
    assert report.text =~ File.cwd!()

    assert report.project_workspace
    assert report.project_workspace.cwd == File.cwd!()

    assert Workspaces.primary_project_workspace(report.project.id).id ==
             report.project_workspace.id

    assert {:ok, secret} =
             Secrets.get_secret_by_key(report.company.id, "LLMOTIONS_API_KEY", scope: "company")

    assert {:ok, "llmotions-secret-value"} = Secrets.get_secret_value(secret.id)

    assert report.agents.ceo.adapter == :openai_chat
    assert report.agents.ceo.config["endpoint"] == "https://cli.llmotions.com/v1"
    assert report.agents.ceo.config["model"] == "gemini-3.5-flash-low"
    assert report.agents.ceo.instructions =~ "Example valid JSON value"
    assert report.agents.ceo.instructions =~ "\\nAttempted fix:"
    assert report.agents.ceo.instructions =~ "rolls back the whole"
    assert report.agents.ceo.instructions =~ "action batch"

    assert report.agents.ceo.runtime_config["profile_id"] ==
             "openai-chat-llmotions-gemini-flash-low"

    assert report.agents.cto.adapter == :openai_chat

    assert report.agents.cto.instructions =~
             "`block_issue.reason` must be a multiline JSON string"

    assert report.agents.cto.instructions =~ "Use `\\n` between"
    assert report.agents.engineer.adapter == :codex
    assert report.agents.qa.adapter == :codex

    for agent <- [report.agents.engineer, report.agents.qa] do
      assert agent.config["base_url"] == "https://cli.llmotions.com/v1"
      assert agent.config["model"] == "gemini-3.5-flash-low"
      assert agent.runtime_config["profile_id"] == Cympho.RuntimeProfiles.custom_id()
    end

    assert AgentRuntimeCapabilities.repo_delivery_capable?(report.agents.engineer)
    assert AgentRuntimeCapabilities.repo_delivery_capable?(report.agents.qa)

    issue = Issues.get_issue!(report.issue.id)
    assert issue.title == "Build Team Pulse launch tracker"
    assert issue.status == :todo
    assert issue.assigned_role == "ceo"
    assert issue.assignee_id == report.agents.ceo.id
    assert get_in(issue.monitor_state, ["dispatch", "pinned_at"])

    preflight = RuntimePreflight.for_issue(issue, autonomy_enabled?: true)
    assert preflight.status == :ready
    assert preflight.agent_id == report.agents.ceo.id

    issues = Companies.list_company_issues(report.company.id)

    cancelled_seed_count =
      Enum.count(issues, &(&1.origin_type == "onboarding" and &1.status == :cancelled))

    assert cancelled_seed_count > 0
  end

  test "setup can prepare a no-secret report that points at credential setup" do
    unique = System.unique_integer([:positive])

    without_chat_provider_env(fn ->
      assert {:ok, report} =
               LLMotions.setup(
                 company_name: "LLMotions Missing Secret #{unique}",
                 issue_prefix: "LMK",
                 api_key: nil,
                 store_secret?: false
               )

      assert report.secret_status == :missing
      assert report.text =~ "missing - add LLMOTIONS_API_KEY before dispatch"
      assert report.preflight.status == :attention
      assert report.preflight.first_action.label == "Chat completion key"
      assert report.preflight.first_action.target_path =~ "key=LLMOTIONS_API_KEY"

      assert report.agents.ceo.runtime_config["profile_id"] ==
               "openai-chat-llmotions-gemma"
    end)
  end

  test "custom models keep a custom profile label instead of claiming Gemma" do
    unique = System.unique_integer([:positive])

    assert {:ok, report} =
             LLMotions.setup(
               company_name: "LLMotions Terra Smoke #{unique}",
               issue_prefix: "LTR",
               model: "gpt-5.6-terra",
               api_key: nil,
               store_secret?: false,
               create_workspace?: false
             )

    for agent <- [report.agents.ceo, report.agents.cto] do
      assert agent.config["model"] == "gpt-5.6-terra"
      assert agent.runtime_config["profile_id"] == Cympho.RuntimeProfiles.custom_id()
    end

    for agent <- [report.agents.engineer, report.agents.qa] do
      assert agent.adapter == :codex
      assert agent.config["base_url"] == "https://cli.llmotions.com/v1"
      assert agent.config["model"] == "gpt-5.6-terra"
      assert agent.runtime_config["profile_id"] == Cympho.RuntimeProfiles.custom_id()
    end

    assert report.text =~ "gpt-5.6-terra"
    refute report.text =~ "openai-chat-llmotions-gemma"
  end

  defp without_chat_provider_env(fun) do
    keys = ~w(DASHSCOPE_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY LLMOTIONS_API_KEY)
    original = Map.new(keys, &{&1, System.get_env(&1)})

    Enum.each(keys, &System.delete_env/1)

    try do
      fun.()
    after
      Enum.each(original, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end
end
