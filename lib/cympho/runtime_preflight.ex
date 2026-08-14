defmodule Cympho.RuntimePreflight do
  @moduledoc """
  Non-invasive runtime readiness checks for saved agent configuration.

  The preflight is intentionally read-only: it checks local command presence,
  configured credential signals, model/provider fields, and dispatch mode
  without starting an agent or calling a provider.
  """

  alias Cympho.Agents
  alias Cympho.Agents.Agent
  alias Cympho.Agents.RuntimeEnv
  alias Cympho.Adapters.ModelCompatibility
  alias Cympho.Adapters.RuntimeOptions
  alias Cympho.Companies
  alias Cympho.Companies.Company
  alias Cympho.DeliveryBriefReadiness
  alias Cympho.Issues.Issue
  alias Cympho.Secrets
  alias Cympho.Workspaces
  alias Cympho.Workspaces.ProjectWorkspace

  @repo_delivery_roles Agent.pr_delivery_roles()

  @type item_status :: :ok | :info | :attention | :blocked
  @type status :: :ready | :review_mode | :attention | :blocked

  @doc """
  Returns a non-secret preflight summary for an agent.

  Options:
    * `:autonomy_enabled?` - overrides dispatcher mode for tests/UI previews.
    * `:secret_count` - count of scoped secrets available for display.
    * `:secret_keys` - scoped secret keys that can supply credentials.
  """
  @spec for_agent(map(), keyword()) :: map()
  def for_agent(agent, opts \\ []) when is_map(agent) do
    adapter = normalize_adapter(map_value(agent, :adapter))
    env_vars = RuntimeEnv.from_agent(agent)
    command = command_for_agent(agent, adapter)
    model = model_for_agent(agent, adapter, env_vars)
    endpoint = endpoint_for_agent(agent, adapter, env_vars)
    secret_count = Keyword.get(opts, :secret_count, 0)
    secret_keys = Keyword.get(opts, :secret_keys, []) |> normalize_secret_keys()
    autonomy_enabled? = Keyword.get(opts, :autonomy_enabled?, dispatcher_enabled?())

    runtime = %{
      agent: agent,
      adapter: adapter,
      command: command,
      model: model,
      env_vars: env_vars,
      secret_count: secret_count,
      secret_keys: secret_keys,
      return_to: Keyword.get(opts, :return_to),
      provider: config_value(agent, "provider"),
      endpoint: endpoint,
      process_preset: config_value(agent, "process_preset")
    }

    items =
      [selected_adapter_item(adapter)] ++
        readiness_items(adapter, runtime) ++
        model_compatibility_items(adapter, runtime) ++
        [execution_mode_item(autonomy_enabled?)]

    status = status_for_items(items, autonomy_enabled?)
    attention_count = Enum.count(items, &(&1.status == :attention))

    %{
      status: status,
      label: status_label(status, attention_count),
      summary: summary(adapter, status, attention_count),
      adapter: adapter,
      command: command,
      model: model,
      items: items,
      first_action: first_action(items)
    }
  end

  @doc """
  Returns a non-secret preflight summary for an issue's dispatch path.

  This uses the dispatcher's read-only routing preview, so assigned agents that
  are not idle/capacity-eligible and auto-route candidates are evaluated the
  same way the dispatcher will evaluate them.

  Options:
    * `:secret_summary_by_agent` - optional `%{agent_id => %{count: n, keys: [...]}}`
      cache for callers that preloaded non-secret secret metadata.
  """
  @spec for_issue(Issue.t(), keyword()) :: map()
  def for_issue(%Issue{} = issue, opts \\ []) do
    case company_runtime_preflight_blocker(issue) do
      {:error, paused} ->
        paused

      :ok ->
        issue_agent_preflight(issue, opts)
    end
  end

  defp issue_agent_preflight(%Issue{} = issue, opts) do
    case Cympho.Orchestrator.Dispatcher.preview_agent_for_issue(issue) do
      {:ok, agent} ->
        agent_opts =
          opts
          |> Keyword.put_new(:return_to, issue_return_to(issue))
          |> put_secret_count(agent)

        preflight =
          for_agent(agent, agent_opts)

        issue_items =
          issue_readiness_items(
            issue,
            agent,
            preflight.adapter,
            Keyword.get(agent_opts, :secret_keys, [])
          )

        items = preflight.items ++ issue_items
        status = status_for_items(items, preflight.status != :review_mode)
        attention_count = Enum.count(items, &(&1.status == :attention))
        summary = summary(preflight.adapter, status, attention_count)
        routed? = is_nil(map_value(issue, :assignee_id))

        %{
          preflight
          | status: status,
            label: status_label(status, attention_count),
            summary: issue_summary(issue, agent, %{preflight | status: status, summary: summary}),
            items: items,
            first_action: first_action(items)
        }
        |> Map.merge(%{
          agent_id: agent.id,
          agent_name: agent.name,
          agent_role: agent.role,
          routed?: routed?
        })

      {:error, :no_agent_available} ->
        role = Cympho.Orchestrator.Dispatcher.Router.infer_role(issue)
        {summary, detail, opts} = dispatch_blocker(issue, role)
        items = [item(:blocked, "Dispatch eligibility", detail, opts)]

        %{
          status: :blocked,
          label: "No agent",
          summary: summary,
          adapter: nil,
          command: nil,
          model: nil,
          agent_id: nil,
          agent_name: nil,
          agent_role: role,
          routed?: is_nil(map_value(issue, :assignee_id)),
          items: items,
          first_action: first_action(items)
        }
    end
  end

  # Fail-closed: unscoped issues are not dispatch-ready (matches Runtime.preflight).
  defp company_runtime_preflight_blocker(%Issue{company_id: nil}) do
    {:error,
     blocked_preflight(
       "Unscoped",
       "This issue has no company_id and cannot be dispatched.",
       "Missing company scope",
       "Assign the issue to a company before dispatch."
     )}
  end

  defp company_runtime_preflight_blocker(%Issue{company_id: company_id}) do
    case Cympho.Repo.get(Company, company_id) do
      %Company{} = company ->
        if Companies.active?(company), do: :ok, else: {:error, paused_company_preflight(company)}

      nil ->
        {:error,
         blocked_preflight(
           "Unscoped",
           "The issue company no longer exists.",
           "Company not found",
           "Re-scope the issue to an active company before dispatch."
         )}
    end
  end

  defp paused_company_preflight(company) do
    detail =
      case company.paused_reason do
        reason when is_binary(reason) and reason != "" ->
          "Company runtime is paused: #{reason}. Resume runtime before starting agents or harnesses."

        _ ->
          "Company runtime is paused. Resume runtime before starting agents or harnesses."
      end

    blocked_preflight(
      "Paused",
      "Company runtime is paused. Agents and harnesses will not start.",
      "Runtime paused",
      detail,
      target_path: "/operations",
      target_label: "Resume the team"
    )
  end

  defp blocked_preflight(label, summary, item_label, detail, opts \\ []) do
    target_path = Keyword.get(opts, :target_path, "/dashboard")
    target_label = Keyword.get(opts, :target_label, "Open dashboard")

    items = [
      item(:blocked, item_label, detail,
        target_path: target_path,
        target_label: target_label
      )
    ]

    %{
      status: :blocked,
      label: label,
      summary: summary,
      adapter: nil,
      command: nil,
      model: nil,
      agent_id: nil,
      agent_name: nil,
      agent_role: nil,
      routed?: false,
      items: items,
      first_action: first_action(items)
    }
  end

  defp dispatcher_enabled? do
    Cympho.Orchestrator.Dispatcher.enabled?()
  rescue
    _ -> false
  end

  defp put_secret_count(opts, agent) do
    secret_summary = Keyword.get(opts, :secret_summary_by_agent)
    agent_id = map_value(agent, :id)

    cond do
      Keyword.has_key?(opts, :secret_count) and Keyword.has_key?(opts, :secret_keys) ->
        opts

      is_map(secret_summary) and is_binary(agent_id) and Map.has_key?(secret_summary, agent_id) ->
        summary = Map.get(secret_summary, agent_id) || %{}

        opts
        |> Keyword.put_new(:secret_count, Map.get(summary, :count, 0))
        |> Keyword.put_new(:secret_keys, Map.get(summary, :keys, []))

      true ->
        secrets = agent_id |> list_agent_secrets()

        opts
        |> Keyword.put_new(:secret_count, length(secrets))
        |> Keyword.put_new(:secret_keys, Enum.map(secrets, & &1.key))
    end
  end

  defp list_agent_secrets(agent_id) when is_binary(agent_id),
    do: Secrets.list_secrets_for_agent(agent_id)

  defp list_agent_secrets(_agent_id), do: []

  defp selected_adapter_item(adapter) do
    item(:ok, "Selected adapter", adapter_label(adapter))
  end

  defp execution_mode_item(true),
    do: item(:ok, "Execution mode", "Autonomous dispatch is enabled.")

  defp execution_mode_item(false) do
    item(:info, "Execution mode", "Review mode only. Agents will not auto-dispatch.",
      target_path: "/operations#runtime-services",
      target_label: "Open service gates"
    )
  end

  defp issue_readiness_items(%Issue{} = issue, %Agent{} = agent, adapter, secret_keys) do
    [
      repo_delivery_runtime_item(issue, agent, adapter, secret_keys),
      workspace_isolation_item(issue, agent, adapter, secret_keys),
      delivery_brief_item(issue, agent)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp repo_delivery_runtime_item(_issue, %Agent{role: role} = agent, adapter, secret_keys)
       when role in @repo_delivery_roles do
    if Cympho.AgentRuntimeCapabilities.repo_delivery_capable?(agent, secret_keys: secret_keys) do
      nil
    else
      item(
        :attention,
        "Repo-capable runtime",
        "#{adapter_label(adapter)} is not configured for repo-delivery capability. Assign this issue to Codex, Claude Code, Cursor, a coding Process preset, Agrenting push delivery, or another remote coding runtime before expecting file changes, tests, branches, or PRs.",
        target_path: agent_config_path(%{agent: agent}, "agent-runtime-profile"),
        target_label: "Open runtime profile"
      )
    end
  end

  defp repo_delivery_runtime_item(_issue, _agent, _adapter, _secret_keys), do: nil

  defp workspace_isolation_item(
         %Issue{} = issue,
         %Agent{role: role} = agent,
         adapter,
         secret_keys
       )
       when role in @repo_delivery_roles do
    if adapter_uses_local_workspace?(adapter) and
         Cympho.AgentRuntimeCapabilities.repo_delivery_capable?(agent, secret_keys: secret_keys) do
      case shared_project_workspace(issue) do
        %ProjectWorkspace{} = project_workspace ->
          item(
            :attention,
            "Workspace isolation",
            "Repo-delivery work would run from shared project workspace #{workspace_label(project_workspace)}. Attach an execution workspace or worktree before parallel file edits so temporary agents do not write into the same checkout.",
            target_path: project_workspace_path(project_workspace),
            target_label: "Open workspace"
          )

        nil ->
          nil
      end
    end
  end

  defp workspace_isolation_item(_issue, _agent, _adapter, _secret_keys), do: nil

  defp adapter_uses_local_workspace?(adapter),
    do: normalize_adapter(adapter) in ~w(claude_code codex cursor openclaw process)

  defp shared_project_workspace(%Issue{execution_workspace_id: id}) when is_binary(id), do: nil

  defp shared_project_workspace(%Issue{project_workspace_id: id}) when is_binary(id) do
    case Workspaces.get_project_workspace(id) do
      {:ok, %ProjectWorkspace{} = project_workspace} -> project_workspace
      {:error, _reason} -> nil
    end
  end

  defp shared_project_workspace(%Issue{project_id: id}) when is_binary(id),
    do: Workspaces.primary_project_workspace(id)

  defp shared_project_workspace(_issue), do: nil

  defp workspace_label(%ProjectWorkspace{name: name, cwd: cwd}) do
    [name, cwd]
    |> Enum.find(&present?/1)
    |> case do
      nil -> "for this project"
      value -> "`#{value}`"
    end
  end

  defp project_workspace_path(%ProjectWorkspace{id: id}) when is_binary(id),
    do: "/workspaces/#{id}"

  defp project_workspace_path(_project_workspace), do: "/workspaces"

  defp delivery_brief_item(%Issue{} = issue, %Agent{role: role})
       when role in @repo_delivery_roles do
    case DeliveryBriefReadiness.evaluate(issue) do
      %{status: :ready} ->
        nil

      %{label: label, passed_count: passed, total: total, next_prompt: next_prompt} ->
        item(
          :attention,
          "Delivery brief",
          "#{label} (#{passed}/#{total} signals). #{next_prompt}",
          target_path: issue_description_path(issue),
          target_label: "Edit issue brief"
        )
    end
  end

  defp delivery_brief_item(_issue, _agent), do: nil

  defp readiness_items("claude_code", runtime) do
    command = first_present([runtime.command, "claude"])

    [
      command_item("Runtime command", command,
        shell?: true,
        target_path: agent_config_path(runtime, "agent-runtime-profile"),
        target_label: "Change profile"
      ),
      claude_credentials_item(command, runtime),
      claude_model_item(runtime),
      claude_endpoint_item(runtime)
    ]
  end

  defp readiness_items("codex", runtime) do
    [
      command_item("CLI command", "codex",
        target_path: agent_config_path(runtime, "agent-runtime-profile"),
        target_label: "Change profile"
      ),
      model_item("Codex model", runtime.model,
        target_path: agent_config_path(runtime, "agent-codex-model"),
        target_label: "Choose model"
      ),
      credentials_item(runtime, ["OPENAI_API_KEY", "CODEX_API_KEY"], "OpenAI/Codex key"),
      item(:ok, "Invocation", "Runs as codex --model #{runtime.model || "default"}.")
    ]
  end

  defp readiness_items("cursor", runtime) do
    [
      command_item("Cursor command", runtime.command || "agent",
        target_path: agent_config_path(runtime, "agent-cursor-command"),
        target_label: "Edit command"
      ),
      model_item("Cursor model", runtime.model,
        target_path: agent_config_path(runtime, "agent-cursor-model"),
        target_label: "Choose model"
      ),
      item(:ok, "Account", "Uses the local Cursor CLI account and installed model access.")
    ]
  end

  defp readiness_items("process", runtime) do
    [
      command_item("Command", runtime.command,
        target_path: agent_config_path(runtime, "agent-process-command"),
        target_label: "Edit command"
      ),
      model_item("Forwarded model", runtime.model,
        target_path: agent_config_path(runtime, "agent-process-model"),
        target_label: "Choose model"
      ),
      item(
        :ok,
        "Preset",
        "Preset #{runtime.process_preset || "custom"} controls args and model forwarding."
      ),
      process_credentials_item(runtime)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp readiness_items("openclaw", runtime) do
    [
      item(:ok, "Provider", runtime.provider || "default provider"),
      model_item("Provider model", runtime.model,
        target_path: agent_config_path(runtime, "agent-openclaw-model"),
        target_label: "Choose model"
      ),
      endpoint_item(runtime.endpoint,
        target_path: agent_config_path(runtime, "agent-openclaw-endpoint"),
        target_label: "Set endpoint"
      )
    ]
  end

  defp readiness_items("openai_chat", runtime) do
    [
      credentials_item(
        runtime,
        openai_chat_credential_keys(runtime),
        "Chat completion key"
      ),
      model_item("Chat model", runtime.model,
        target_path: agent_config_path(runtime, "agent-openai-chat-model"),
        target_label: "Set model"
      ),
      openai_chat_endpoint_item(runtime.endpoint,
        target_path: agent_config_path(runtime, "agent-openai-chat-endpoint"),
        target_label: "Set endpoint"
      ),
      openai_chat_capability_item()
    ] ++ openai_chat_request_url_items(runtime.endpoint)
  end

  defp readiness_items("agrenting", runtime) do
    config = runtime.agent.config || %{}

    [
      credentials_item(runtime, ["AGRENTING_API_KEY"], "Agrenting API key"),
      required_config_item(config, "agent_did", "Remote agent DID",
        target_path: agent_config_path(runtime, "agent-runtime-profile"),
        target_label: "Open agent config"
      ),
      required_config_item(config, "capability", "Default capability",
        target_path: agent_config_path(runtime, "agent-runtime-profile"),
        target_label: "Open agent config"
      ),
      required_config_item(config, "max_price", "Max price per run",
        target_path: agent_config_path(runtime, "agent-runtime-profile"),
        target_label: "Open agent config"
      ),
      agrenting_delivery_item(runtime)
    ]
  end

  defp readiness_items(_adapter, _runtime) do
    [item(:attention, "Adapter contract", "This adapter does not expose readiness checks yet.")]
  end

  defp openai_chat_credential_keys(runtime) do
    endpoint = runtime.endpoint |> to_string() |> String.downcase()
    model = runtime.model |> to_string() |> String.downcase()

    cond do
      String.contains?(endpoint, "llmotions") ->
        ["LLMOTIONS_API_KEY", "OPENAI_API_KEY", "DASHSCOPE_API_KEY", "ANTHROPIC_API_KEY"]

      String.contains?(endpoint, "dashscope") or String.starts_with?(model, "qwen") ->
        ["DASHSCOPE_API_KEY", "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "LLMOTIONS_API_KEY"]

      true ->
        ["OPENAI_API_KEY", "DASHSCOPE_API_KEY", "ANTHROPIC_API_KEY", "LLMOTIONS_API_KEY"]
    end
  end

  defp claude_credentials_item(command, runtime) do
    cond do
      credentials_present?(runtime, ["ANTHROPIC_API_KEY"]) ->
        item(:ok, "Credentials", "Anthropic-compatible credentials are configured.")

      command not in [nil, "", "claude"] ->
        item(
          :ok,
          "Credentials",
          "#{command} can source credentials from a wrapper or $HOME/.cld."
        )

      true ->
        item(:attention, "Credentials", "Add ANTHROPIC_API_KEY or choose a wrapper command.",
          target_path:
            secret_setup_path(
              "ANTHROPIC_API_KEY",
              "Anthropic-compatible runtime credential",
              Map.get(runtime, :return_to)
            ),
          target_label: "Add secret"
        )
    end
  end

  defp process_credentials_item(runtime) do
    keys =
      RuntimeOptions.process_preset_required_keys(runtime.process_preset, runtime.command)

    case keys do
      [] ->
        nil

      keys ->
        credentials_item(runtime, keys, process_credentials_label(runtime.process_preset))
    end
  end

  defp process_credentials_label("codex"), do: "OpenAI/Codex key"
  defp process_credentials_label("claude_code"), do: "Anthropic key"
  defp process_credentials_label(_preset), do: "Provider key"

  defp credentials_item(runtime, keys, label) do
    if credentials_present?(runtime, keys) do
      item(:ok, label, "Credential source is configured through secrets or env.")
    else
      item(:attention, label, "Add #{Enum.join(keys, " or ")} as a secret or runtime env var.",
        target_path:
          secret_setup_path(
            List.first(keys),
            "#{label} for agent runtime",
            Map.get(runtime, :return_to)
          ),
        target_label: "Add secret"
      )
    end
  end

  defp credentials_present?(runtime, keys) do
    Enum.any?(keys, &(&1 in runtime.secret_keys)) ||
      Enum.any?(keys, fn key ->
        runtime.env_vars |> Map.get(key) |> present?()
      end)
  end

  defp normalize_secret_keys(keys) when is_list(keys) do
    keys
    |> Enum.filter(&is_binary/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_secret_keys(_keys), do: []

  defp command_item(label, command, opts) when command in [nil, ""] do
    item(:attention, label, "Choose the command Cympho should execute.", opts)
  end

  defp command_item(label, command, opts) do
    if command_available?(command, opts) do
      item(:ok, label, "#{command} was found on this machine.")
    else
      item(:blocked, label, "#{command} was not found in PATH or configured shell env.", opts)
    end
  end

  defp model_item(label, model, opts) when model in [nil, ""],
    do: item(:attention, label, "Choose a model before autonomous runs.", opts)

  defp model_item(label, model, _opts), do: item(:ok, label, model)

  defp endpoint_item(endpoint, opts) when endpoint in [nil, ""],
    do: item(:attention, "Gateway endpoint", "Add the gateway URL before autonomous runs.", opts)

  defp endpoint_item(endpoint, _opts), do: item(:ok, "Gateway endpoint", endpoint)

  defp openai_chat_endpoint_item(endpoint, opts) when endpoint in [nil, ""] do
    item(
      :attention,
      "Configured endpoint",
      "Add the chat completions URL before autonomous runs.",
      opts
    )
  end

  defp openai_chat_endpoint_item(endpoint, _opts), do: item(:ok, "Configured endpoint", endpoint)

  defp openai_chat_capability_item do
    item(
      :info,
      "Execution capability",
      "Chat adapters can emit Cympho actions, but cannot edit files, run tests, create branches, or open real PRs without a repo-capable runtime."
    )
  end

  defp openai_chat_request_url_items(endpoint) when endpoint in [nil, ""], do: []

  defp openai_chat_request_url_items(endpoint) do
    [
      item(
        :ok,
        "Request URL",
        Cympho.Adapters.OpenAIChatAdapter.normalize_chat_url(endpoint)
      )
    ]
  end

  defp model_compatibility_items(adapter, runtime) do
    config = %{
      "model" => runtime.model,
      "provider" => runtime.provider,
      "command" => runtime.command,
      "endpoint" => runtime.endpoint
    }

    case ModelCompatibility.validate(adapter, config) do
      :ok ->
        []

      {:error, message} ->
        [
          item(:attention, "Model/harness match", message,
            target_path: agent_config_path(runtime, "agent-runtime-profile"),
            target_label: "Fix model"
          )
        ]
    end
  end

  defp claude_model_item(%{model: model}) when model in [nil, ""] do
    item(:ok, "Provider model", "Default from Claude, ANTHROPIC_MODEL, or wrapper routing.")
  end

  defp claude_model_item(%{model: model}), do: item(:ok, "Provider model", model)

  defp claude_endpoint_item(%{endpoint: endpoint}) when endpoint in [nil, ""] do
    item(:ok, "Gateway endpoint", "Default Anthropic endpoint or wrapper routing.")
  end

  defp claude_endpoint_item(%{endpoint: endpoint}), do: item(:ok, "Gateway endpoint", endpoint)

  defp required_config_item(config, key, label, opts) do
    case Map.get(config, key) || atom_key(config, key) do
      value when value not in [nil, ""] -> item(:ok, label, to_string(value))
      _ -> item(:attention, label, "Set by the remote-agent hire flow.", opts)
    end
  end

  defp agrenting_delivery_item(runtime) do
    case agrenting_delivery_mode(runtime.agent) do
      "push" ->
        if agrenting_repo_token_present?(runtime) do
          item(:ok, "Delivery mode", "Push delivery has a repo token source configured.")
        else
          item(
            :attention,
            "Repo push token",
            "Add AGRENTING_REPO_ACCESS_TOKEN or GITHUB_TOKEN before using Agrenting push delivery for repo work.",
            target_path:
              secret_setup_path(
                "AGRENTING_REPO_ACCESS_TOKEN",
                "Agrenting repo access token for push delivery",
                Map.get(runtime, :return_to)
              ),
            target_label: "Add repo token"
          )
        end

      _ ->
        item(
          :info,
          "Delivery mode",
          "Output mode can return text and artifacts, but is not counted as repo delivery until push mode and a repo token are configured."
        )
    end
  end

  defp agrenting_delivery_mode(agent) do
    value =
      runtime_config_value(agent, "delivery_mode") ||
        config_value(agent, "delivery_mode") ||
        "output"

    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp agrenting_repo_token_present?(runtime) do
    repo_token =
      runtime_config_value(runtime.agent, "repo_access_token") ||
        config_value(runtime.agent, "repo_access_token")

    present?(repo_token) or
      credentials_present?(runtime, ["AGRENTING_REPO_ACCESS_TOKEN", "GITHUB_TOKEN"])
  end

  defp item(status, label, detail, opts \\ []) do
    target =
      opts
      |> Keyword.take([:target_id, :target_label, :target_path])
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Map.new()

    Map.merge(%{status: status, label: label, detail: detail}, target)
  end

  defp first_action(items) do
    Enum.find(items, &(&1.status == :blocked)) ||
      Enum.find(items, &(&1.status == :attention)) ||
      Enum.find(items, &(&1.status == :info))
  end

  defp status_for_items(items, autonomy_enabled?) do
    blocked_count = Enum.count(items, &(&1.status == :blocked))
    attention_count = Enum.count(items, &(&1.status == :attention))

    cond do
      blocked_count > 0 -> :blocked
      attention_count > 0 -> :attention
      not autonomy_enabled? -> :review_mode
      true -> :ready
    end
  end

  defp command_available?(command, opts) do
    executable_available?(command) or
      (Keyword.get(opts, :shell?, false) and shell_command_available?(command))
  end

  defp executable_available?(command) do
    cond do
      command in [nil, ""] ->
        false

      String.starts_with?(command, "/") ->
        File.exists?(command) and not File.dir?(command)

      true ->
        not is_nil(System.find_executable(command))
    end
  end

  # `for_issue/2` is mapped over every card the kanban board and issues index
  # render, so this probe used to fork one login shell per card, serially,
  # inside the LiveView process — and `bash -lc` sources the user's profile,
  # which can be arbitrarily slow. Whether a command exists changes on the scale
  # of a deploy, not a render, so the answer is cached and the fork is bounded.
  @shell_probe_ttl_ms :timer.seconds(60)
  @shell_probe_timeout_ms 2_000
  @shell_probe_table :cympho_shell_command_probe

  defp shell_command_available?(command) do
    now = System.monotonic_time(:millisecond)

    case cached_shell_probe(command, now) do
      {:ok, available?} ->
        available?

      :miss ->
        available? = run_shell_probe(command)
        cache_shell_probe(command, available?, now)
        available?
    end
  end

  defp run_shell_probe(command) do
    quoted = shell_quote(command)

    script =
      "shopt -s expand_aliases 2>/dev/null || true; source \"$HOME/.cld\" 2>/dev/null || true; command -v #{quoted} >/dev/null 2>&1"

    task =
      Task.Supervisor.async_nolink(Cympho.TaskSupervisor, fn ->
        System.cmd("bash", ["-lc", script], stderr_to_stdout: true)
      end)

    case Task.yield(task, @shell_probe_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {_output, 0}} -> true
      _ -> false
    end
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  defp cached_shell_probe(command, now) do
    ensure_shell_probe_table()

    case :ets.lookup(@shell_probe_table, command) do
      [{^command, available?, expires_at}] when expires_at > now -> {:ok, available?}
      _ -> :miss
    end
  rescue
    _ -> :miss
  end

  defp cache_shell_probe(command, available?, now) do
    ensure_shell_probe_table()
    :ets.insert(@shell_probe_table, {command, available?, now + @shell_probe_ttl_ms})
    :ok
  rescue
    _ -> :ok
  end

  defp ensure_shell_probe_table do
    case :ets.whereis(@shell_probe_table) do
      :undefined ->
        :ets.new(@shell_probe_table, [:named_table, :public, :set, read_concurrency: true])

      _tid ->
        :ok
    end
  rescue
    # Race: another process created the table between whereis and new.
    ArgumentError -> :ok
  end

  defp command_for_agent(agent, "claude_code") do
    config_value(agent, "command") ||
      runtime_config_value(agent, "command") ||
      Application.get_env(:cympho, :claude_code_command) ||
      System.get_env("CYMPHO_CLAUDE_COMMAND") ||
      "claude"
  end

  defp command_for_agent(_agent, "codex"), do: "codex"

  defp command_for_agent(agent, adapter) when adapter in ["cursor", "process"] do
    runtime_config_value(agent, "command") || config_value(agent, "command") ||
      adapter_label(adapter)
  end

  defp command_for_agent(_agent, adapter), do: adapter_label(adapter)

  defp agent_config_path(%{agent: agent}, anchor) do
    case map_value(agent, :id) do
      id when is_binary(id) and id != "" -> "/agents/#{id}?tab=configuration##{anchor}"
      _ -> nil
    end
  end

  defp issue_return_to(%Issue{id: id}) when is_binary(id), do: "/issues/#{id}"
  defp issue_return_to(_issue), do: nil

  defp issue_description_path(%Issue{id: id}) when is_binary(id),
    do: "/issues/#{id}#issue-description"

  defp issue_description_path(_issue), do: nil

  defp secret_setup_path(key, description, return_to) when is_binary(key) and key != "" do
    query =
      [
        {"key", key},
        {"scope", "company"},
        {"description", description},
        {"return_to", return_to}
      ]
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> URI.encode_query()

    "/settings/secrets?#{query}"
  end

  defp secret_setup_path(_key, _description, _return_to), do: "/settings/secrets"

  defp model_for_agent(agent, adapter, _env_vars)
       when adapter in ["codex", "cursor", "process"] do
    runtime_config_value(agent, "model") || config_value(agent, "model")
  end

  defp model_for_agent(agent, "openai_chat", env_vars) do
    runtime_config_value(agent, "model") ||
      config_value(agent, "model") ||
      env_vars["LLMOTIONS_MODEL"] ||
      env_vars["OPENAI_MODEL"] ||
      env_vars["DASHSCOPE_MODEL"] ||
      env_vars["MODEL"]
  end

  defp model_for_agent(_agent, "claude_code", env_vars) do
    env_vars["ANTHROPIC_MODEL"] ||
      env_vars["ANTHROPIC_DEFAULT_SONNET_MODEL"] ||
      env_vars["OPENAI_MODEL"] ||
      env_vars["MODEL"] ||
      System.get_env("ANTHROPIC_MODEL") ||
      System.get_env("ANTHROPIC_DEFAULT_SONNET_MODEL")
  end

  defp model_for_agent(agent, _adapter, _env_vars) do
    runtime_config_value(agent, "model") || config_value(agent, "model")
  end

  defp endpoint_for_agent(agent, "claude_code", env_vars) do
    env_vars["ANTHROPIC_BASE_URL"] ||
      env_vars["ANTHROPIC_API_BASE"] ||
      env_vars["OPENAI_BASE_URL"] ||
      System.get_env("ANTHROPIC_BASE_URL") ||
      System.get_env("ANTHROPIC_API_BASE") ||
      config_value(agent, "endpoint") ||
      config_value(agent, "base_url")
  end

  defp endpoint_for_agent(agent, "openai_chat", env_vars) do
    config_value(agent, "endpoint") ||
      config_value(agent, "base_url") ||
      env_vars["LLMOTIONS_BASE_URL"] ||
      env_vars["OPENAI_BASE_URL"] ||
      env_vars["DASHSCOPE_BASE_URL"]
  end

  defp endpoint_for_agent(agent, _adapter, _env_vars) do
    config_value(agent, "endpoint") || config_value(agent, "base_url")
  end

  defp status_label(:ready, _count), do: "Ready"
  defp status_label(:review_mode, _count), do: "Review mode only"
  defp status_label(:blocked, _count), do: "Blocked"
  defp status_label(:attention, 1), do: "1 config check"
  defp status_label(:attention, count), do: "#{count} config checks"

  defp summary(adapter, :ready, _count), do: "#{adapter_label(adapter)} has basic runtime signal."

  defp summary(adapter, :review_mode, _count) do
    "#{adapter_label(adapter)} is configured, but dispatch is disabled for review mode."
  end

  defp summary(adapter, :blocked, _count) do
    "#{adapter_label(adapter)} points at a command Cympho cannot find on this machine."
  end

  defp summary(adapter, _status, count) do
    "#{adapter_label(adapter)} needs #{count} runtime check#{plural(count)} before autonomous runs."
  end

  defp issue_summary(issue, agent, preflight) do
    if is_nil(map_value(issue, :assignee_id)) do
      "Auto-route would choose #{agent.name}. #{preflight.summary}"
    else
      "#{agent.name} is assigned. #{preflight.summary}"
    end
  end

  defp no_agent_summary(issue, role) do
    if is_nil(map_value(issue, :assignee_id)) do
      "No idle eligible #{role_label(role)} is available for this auto-route candidate."
    else
      "The assigned agent is not currently eligible for #{role_label(role)} dispatch."
    end
  end

  defp dispatch_blocker(issue, role) do
    case map_value(issue, :assignee_id) do
      nil ->
        role_name = role_label(role)

        target_opts =
          if role == :ceo do
            [target_path: "/agents/new", target_label: "Add CEO agent"]
          else
            []
          end

        {no_agent_summary(issue, role),
         "Add or free an eligible #{role_name} before this issue can dispatch.", target_opts}

      assignee_id ->
        case Agents.get_agent(assignee_id) do
          {:ok, agent} ->
            assigned_agent_blocker(issue, agent, role)

          {:error, _} ->
            role_name = role_label(role)

            {"The assigned agent no longer exists for #{role_name} dispatch.",
             "Reassign this issue or clear the assignee so auto-route can choose an eligible #{role_name}.",
             []}
        end
    end
  end

  defp assigned_agent_blocker(issue, agent, role) do
    role_name = role_label(role)
    name = agent_name(agent)

    cond do
      not idle_agent?(agent) ->
        {"#{name} is #{agent_status_label(agent.status)}, so it cannot pick up #{role_name} dispatch.",
         "Wait for #{name} to return idle, stop or release its current run, or assign a different eligible #{role_name}.",
         []}

      Agents.is_agent_at_capacity?(agent) ->
        {"#{name} is at its configured concurrency limit.",
         "Wait for a run to finish or raise its concurrency limit before dispatching this issue.",
         []}

      not same_company?(issue, agent) ->
        {"#{name} belongs to a different company scope.",
         "Assign an agent in this company or clear the assignee for auto-route.", []}

      not Issue.role_authorized?(agent.role, role) ->
        {"#{name} is not authorized for #{role_name} work.",
         "Assign an eligible #{role_name} or a higher-ranking supervisor.", []}

      true ->
        {"The assigned agent is not currently eligible for #{role_name} dispatch.",
         "Add or free an eligible #{role_name} before this issue can dispatch.", []}
    end
  end

  defp role_label(nil), do: "agent"
  defp role_label(role), do: Agent.role_label(role)

  defp config_value(agent, key), do: nested_value(agent, :config, key)
  defp runtime_config_value(agent, key), do: nested_value(agent, :runtime_config, key)

  defp nested_value(agent, field, key) do
    case map_value(agent, field) do
      %{} = map -> Map.get(map, key) || atom_key(map, key)
      _ -> nil
    end
  end

  defp map_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp atom_key(map, key) do
    Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> nil
  end

  defp normalize_adapter(nil), do: "unknown"
  defp normalize_adapter(adapter), do: adapter |> to_string() |> String.trim()

  defp adapter_label(""), do: "Unknown adapter"
  defp adapter_label(nil), do: "Unknown adapter"
  defp adapter_label("openai_chat"), do: "OpenAI Chat"
  defp adapter_label(:openai_chat), do: "OpenAI Chat"

  defp adapter_label(adapter) do
    adapter
    |> to_string()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp first_present(values) do
    Enum.find(values, &present?/1)
  end

  defp idle_agent?(agent), do: map_value(agent, :status) in [:idle, "idle"]

  # Fail-closed: both sides must share a non-nil company_id (matches Runtime /
  # Issues.checkout / Dispatcher after ot-tenancy-fail-closed).
  defp same_company?(%Issue{company_id: company_id}, %{company_id: company_id})
       when is_binary(company_id) and company_id != "",
       do: true

  defp same_company?(_issue, _agent), do: false

  defp agent_name(agent), do: map_value(agent, :name) || "Assigned agent"

  defp agent_status_label(nil), do: "not idle"

  defp agent_status_label(status) do
    status
    |> to_string()
    |> String.replace("_", " ")
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false

  defp shell_quote(value), do: "'" <> String.replace(to_string(value), "'", "'\"'\"'") <> "'"
  defp plural(1), do: ""
  defp plural(_), do: "s"
end
