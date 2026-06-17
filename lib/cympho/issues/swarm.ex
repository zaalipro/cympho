defmodule Cympho.Issues.Swarm do
  @moduledoc """
  Launches a temporary non-engineering agent swarm for a newly-created CEO issue.

  Swarm configuration is stored on the parent issue's `monitor_state["swarm"]`
  and launch artifacts are regular agents/issues/blockers so the existing
  dispatcher, review gates, and issue tree stay authoritative.
  """

  alias Cympho.Agents
  alias Cympho.Agents.Agent
  alias Cympho.Adapters.RuntimeOptions
  alias Cympho.Comments
  alias Cympho.Companies
  alias Cympho.Issues
  alias Cympho.Issues.Issue
  alias Cympho.Issues.SwarmEvents
  alias Cympho.Proxies

  @default_agent_count 3
  @max_agent_count 12
  @protocol_version 1
  @allowed_worker_roles [
    :product_manager,
    :designer,
    :researcher,
    :marketer,
    :content_strategist,
    :sales_development,
    :customer_support
  ]
  @default_worker_roles [:product_manager, :designer, :researcher]
  @reasoning_efforts ~w(auto low medium high)
  @protocol_rules [
    independent: "Independent first pass",
    diverse_lenses: "Role and lens diversity",
    evidence: "Evidence over consensus",
    dissent: "Preserve dissent",
    cto_synthesis: "Single CTO synthesis",
    ceo_handoff: "CEO decision handoff"
  ]
  @role_lenses %{
    product_manager: %{
      name: "Market and prioritization",
      focus: "Segment, value, priority, and the smallest decision that moves the owner forward."
    },
    designer: %{
      name: "User journey and usability",
      focus: "User flow, comprehension, trust, and friction that could change the recommendation."
    },
    researcher: %{
      name: "Evidence and uncertainty",
      focus: "What is known, what is assumed, confidence level, and which facts need validation."
    },
    marketer: %{
      name: "Positioning and demand",
      focus: "Audience, message, channel, and proof that the market would care."
    },
    content_strategist: %{
      name: "Narrative and information architecture",
      focus: "Storyline, clarity, ordering, and how the recommendation should be communicated."
    },
    sales_development: %{
      name: "Buyer objections and qualification",
      focus: "Who would buy, what would block them, and which objections need handling."
    },
    customer_support: %{
      name: "Support burden and failure modes",
      focus: "Customer confusion, operating load, escalations, and post-decision risk."
    }
  }
  @challenge_lenses [
    "Name the strongest counterargument to your own recommendation.",
    "Call out one assumption that would reverse your recommendation.",
    "Prefer concrete evidence; mark guesses as assumptions.",
    "Find the smallest next decision the CEO can make safely.",
    "Separate reversible choices from high-risk commitments."
  ]

  @type worker_spec :: %{
          role: atom() | nil,
          adapter: atom() | nil,
          process_preset: String.t() | nil,
          model: String.t() | nil,
          reasoning_effort: String.t() | nil,
          proxy_profile: String.t() | nil,
          lens: map() | nil
        }

  @type config :: %{
          enabled: boolean(),
          agent_count: pos_integer(),
          mix: [worker_spec()],
          proxy: %{
            enabled: boolean(),
            mode: String.t(),
            profile: String.t() | nil,
            pool: [String.t()],
            profile_ids: [String.t()]
          }
        }

  @doc """
  Returns true when attrs explicitly request swarm launch.
  """
  def enabled?(attrs), do: attrs |> raw_swarm_params() |> raw_enabled?()

  @doc """
  Normalizes UI/API swarm params into an internal config.

  Invalid roles are ignored, count is clamped, and raw proxy URLs are not
  accepted here. Proxy routing is represented as a named profile so installs can
  resolve it through their own secrets or managed egress layer.
  """
  @spec normalize_config(map()) :: config()
  def normalize_config(attrs) when is_map(attrs) do
    raw = raw_swarm_params(attrs)
    enabled? = raw_enabled?(raw)
    agent_count = raw_agent_count(raw)
    proxy = raw_proxy(raw, attrs)
    mix = raw_mix(raw, agent_count)

    %{
      enabled: enabled?,
      agent_count: agent_count,
      mix: mix,
      proxy: proxy
    }
  end

  def normalize_config(_attrs), do: normalize_config(%{})

  @doc """
  Embeds a normalized swarm config into `monitor_state` before issue insert.
  """
  def embed_config(attrs) when is_map(attrs) do
    config = normalize_config(attrs)

    if config.enabled and authorized?(attrs) do
      monitor_state =
        attrs
        |> get_param(:monitor_state)
        |> normalize_map()
        |> Map.put("swarm", monitor_state_payload(config, "pending"))

      put_param(attrs, :monitor_state, monitor_state)
    else
      attrs
    end
  end

  def embed_config(attrs), do: attrs

  @doc """
  Creates temporary swarm agents, their worker issues, and the CTO/CEO blockers.
  """
  def launch(%Issue{} = parent, attrs) when is_map(attrs) do
    config = normalize_config(attrs)

    if config.enabled and authorized?(attrs) do
      do_launch(parent, config)
    else
      {:ok, parent}
    end
  end

  def launch(%Issue{} = parent, _attrs), do: {:ok, parent}

  defp do_launch(%Issue{} = parent, config) do
    specs = expanded_mix(config)

    SwarmEvents.record(parent, %{
      event_type: "launch_started",
      status: "info",
      message: "Swarm launch started with #{config.agent_count} temporary workers.",
      metadata: %{
        "agent_count" => config.agent_count,
        "mix_rows" => length(config.mix),
        "proxy_mode" => config.proxy.mode
      }
    })

    result =
      with {:ok, temp_agents} <- create_temp_agents(parent, specs),
           :ok <-
             SwarmEvents.record(parent, %{
               event_type: "temporary_agents_created",
               status: "success",
               message: "Created #{length(temp_agents)} hidden one-time worker agents.",
               metadata: %{"agent_ids" => Enum.map(temp_agents, & &1.id)}
             }),
           {:ok, worker_issues} <- create_worker_issues(parent, temp_agents, specs),
           :ok <-
             SwarmEvents.record(parent, %{
               event_type: "worker_issues_created",
               status: "success",
               message: "Created #{length(worker_issues)} independent worker packets.",
               metadata: %{"worker_issue_ids" => Enum.map(worker_issues, & &1.id)}
             }),
           {:ok, cto_issue} <- create_cto_issue(parent, worker_issues, config),
           :ok <-
             SwarmEvents.record(parent, %{
               event_type: "cto_issue_created",
               status: "success",
               issue_id: cto_issue.id,
               message: "Created CTO synthesis gate #{cto_issue.identifier || cto_issue.id}.",
               metadata: %{"cto_issue_id" => cto_issue.id}
             }),
           :ok <- link_swarm_dependencies(parent, cto_issue, worker_issues),
           :ok <-
             SwarmEvents.record(parent, %{
               event_type: "dependencies_linked",
               status: "success",
               issue_id: cto_issue.id,
               message: "Linked worker packets to CTO synthesis and CTO synthesis to CEO parent.",
               metadata: %{
                 "worker_issue_ids" => Enum.map(worker_issues, & &1.id),
                 "cto_issue_id" => cto_issue.id
               }
             }),
           {:ok, blocked_cto} <-
             block_for_swarm(cto_issue, cto_blocker_note(parent, worker_issues)),
           :ok <-
             SwarmEvents.record(parent, %{
               event_type: "cto_blocked_on_workers",
               status: "info",
               issue_id: blocked_cto.id,
               message: "CTO synthesis is blocked until all worker packets close.",
               metadata: %{"worker_issue_ids" => Enum.map(worker_issues, & &1.id)}
             }),
           {:ok, blocked_parent} <- block_for_swarm(parent, parent_blocker_note(cto_issue)),
           :ok <-
             SwarmEvents.record(parent, %{
               event_type: "parent_blocked_on_cto",
               status: "info",
               message: "CEO parent is blocked on CTO synthesis.",
               metadata: %{"cto_issue_id" => cto_issue.id}
             }),
           {:ok, updated_parent} <-
             persist_launched_state(
               blocked_parent,
               config,
               specs,
               temp_agents,
               worker_issues,
               blocked_cto
             ) do
        enqueue_worker_wakes(worker_issues)

        SwarmEvents.record(updated_parent, %{
          event_type: "worker_wakes_enqueued",
          status: "success",
          message: "Queued #{length(worker_issues)} worker wakes for dispatch.",
          metadata: %{"worker_issue_ids" => Enum.map(worker_issues, & &1.id)}
        })

        SwarmEvents.record(updated_parent, %{
          event_type: "launch_ready",
          status: "success",
          message: "Swarm is live: workers feed CTO synthesis, then CEO handoff.",
          metadata: %{
            "agent_count" => config.agent_count,
            "cto_issue_id" => blocked_cto.id,
            "worker_issue_ids" => Enum.map(worker_issues, & &1.id)
          }
        })

        {:ok, updated_parent}
      end

    case result do
      {:ok, updated_parent} ->
        {:ok, updated_parent}

      {:error, reason} = error ->
        SwarmEvents.record(parent, %{
          event_type: "launch_failed",
          status: "error",
          message: "Swarm launch failed: #{format_event_reason(reason)}",
          metadata: %{"reason" => inspect(reason)}
        })

        error
    end
  end

  defp create_temp_agents(%Issue{} = parent, specs) do
    specs
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {spec, index}, {:ok, agents} ->
      attrs = temp_agent_attrs(parent, spec, index)

      case Agents.do_create_agent(attrs) do
        {:ok, agent} ->
          maybe_start_agent_heartbeat(agent)
          {:cont, {:ok, [agent | agents]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, agents} -> {:ok, Enum.reverse(agents)}
      other -> other
    end
  end

  defp temp_agent_attrs(%Issue{} = parent, spec, index) do
    role = spec.role
    adapter = spec.adapter || Cympho.Adapters.Registry.default_adapter()

    config =
      adapter
      |> process_defaults(spec)
      |> Map.merge(%{
        "temporary" => true,
        "one_time" => true,
        "hidden" => true,
        "process_preset" => spec.process_preset,
        "proxy_profile" => spec.proxy_profile,
        "model" => spec.model,
        "reasoning_effort" => spec.reasoning_effort
      })
      |> maybe_put_swarm_system_prompt(adapter, spec, index)
      |> drop_blank_values()

    runtime_config =
      %{
        "swarm" =>
          %{
            "temporary" => true,
            "one_time" => true,
            "hidden" => true,
            "parent_issue_id" => parent.id,
            "worker_index" => index,
            "role" => Atom.to_string(role),
            "harness" => Atom.to_string(adapter),
            "process_preset" => spec.process_preset,
            "model" => spec.model,
            "reasoning_effort" => spec.reasoning_effort,
            "proxy_profile" => spec.proxy_profile,
            "lens" => lens_payload(spec.lens),
            "protocol" => protocol_payload()
          }
          |> drop_blank_values()
      }

    %{
      name: "Swarm #{index} #{Agent.role_label(role)}",
      role: role,
      title: "Temporary #{Agent.role_label(role)}",
      status: :idle,
      company_id: parent.company_id,
      project_id: parent.project_id,
      parent_id: parent.assignee_id,
      adapter: adapter,
      config: config,
      runtime_config: runtime_config,
      context_mode: "issue",
      max_concurrent_jobs: 1,
      instructions: temp_agent_instructions(parent, spec, index)
    }
  end

  defp maybe_put_swarm_system_prompt(config, :openai_chat, spec, index) do
    Map.put(config, "system_prompt", temp_agent_system_prompt(spec, index))
  end

  defp maybe_put_swarm_system_prompt(config, _adapter, _spec, _index), do: config

  defp process_defaults(:process, %{process_preset: preset}) when is_binary(preset) do
    preset
    |> RuntimeOptions.process_defaults()
    |> Map.put("process_preset", preset)
  end

  defp process_defaults(_adapter, _spec), do: %{}

  defp temp_agent_system_prompt(spec, index) do
    lens = spec.lens || worker_lens(spec.role, index)

    """
    You are a temporary Cympho swarm worker. Work only from the supplied issue
    context and your assigned lens. Do not implement code, call tools, or claim
    engineering delivery.

    Output contract is mandatory:
    - Start the response with exactly: [delivery]
    - Do not wrap the packet in a code fence.
    - Use the exact packet headings in order, and do not omit any heading:
      Lens, Recommendation, Evidence, Assumptions, Risks,
      Dissent / alternative, Confidence, CTO synthesis notes.
    - Deliver to CTO synthesis only; do not hand work directly to CEO.
    - After the packet, emit exactly one cympho-actions JSON block that marks
      only this swarm worker packet complete:

      ```cympho-actions
      {"actions":[{"type":"swarm_worker_complete","summary":"one sentence summary for CTO synthesis"}]}
      ```

    Lens: #{lens.name}
    """
  end

  defp create_worker_issues(%Issue{} = parent, agents, specs) do
    agents
    |> Enum.zip(specs)
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {{agent, spec}, index}, {:ok, issues} ->
      case Issues.create_issue(worker_issue_attrs(parent, agent, spec, index)) do
        {:ok, issue} -> {:cont, {:ok, [issue | issues]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, issues} -> {:ok, Enum.reverse(issues)}
      other -> other
    end
  end

  defp worker_issue_attrs(%Issue{} = parent, %Agent{} = agent, spec, index) do
    %{
      title: "Swarm #{index}: #{Agent.role_label(agent.role)} packet for #{parent.title}",
      description: worker_issue_description(parent, agent, spec, index),
      status: :todo,
      priority: parent.priority || :medium,
      company_id: parent.company_id,
      project_id: parent.project_id,
      goal_id: parent.goal_id,
      parent_id: parent.id,
      assignee_id: agent.id,
      assigned_role: Atom.to_string(agent.role),
      origin_type: "swarm_worker",
      origin_id: parent.id,
      request_depth: (parent.request_depth || 0) + 1,
      monitor_state: %{
        "swarm" =>
          %{
            "role" => "worker",
            "parent_issue_id" => parent.id,
            "agent_id" => agent.id,
            "worker_index" => index,
            "harness" => spec.adapter && Atom.to_string(spec.adapter),
            "process_preset" => spec.process_preset,
            "model" => spec.model,
            "reasoning_effort" => spec.reasoning_effort,
            "proxy_profile" => spec.proxy_profile,
            "lens" => lens_payload(spec.lens),
            "protocol" => protocol_payload()
          }
          |> drop_blank_values()
      }
    }
  end

  defp create_cto_issue(%Issue{} = parent, worker_issues, config) do
    attrs =
      %{
        title: "Synthesize swarm delivery for #{parent.title}",
        description: cto_issue_description(parent, worker_issues, config),
        status: :todo,
        priority: parent.priority || :medium,
        company_id: parent.company_id,
        project_id: parent.project_id,
        goal_id: parent.goal_id,
        parent_id: parent.id,
        assigned_role: "cto",
        origin_type: "swarm_cto_review",
        origin_id: parent.id,
        request_depth: (parent.request_depth || 0) + 1,
        monitor_state: %{
          "swarm" =>
            %{
              "role" => "cto_synthesis",
              "parent_issue_id" => parent.id,
              "worker_issue_ids" => Enum.map(worker_issues, & &1.id),
              "agent_count" => config.agent_count,
              "proxy_mode" => config.proxy.mode,
              "proxy_profile" => config.proxy.profile,
              "protocol" => protocol_payload()
            }
            |> drop_blank_values()
        }
      }
      |> maybe_assign_cto(parent.company_id)

    Issues.create_issue(attrs)
  end

  defp maybe_assign_cto(attrs, company_id) when is_binary(company_id) do
    case Agents.get_company_cto(company_id) do
      {:ok, cto} -> Map.put(attrs, :assignee_id, cto.id)
      {:error, :not_found} -> attrs
    end
  end

  defp maybe_assign_cto(attrs, _company_id), do: attrs

  defp link_swarm_dependencies(parent, cto_issue, worker_issues) do
    with :ok <- add_blockers(cto_issue, worker_issues),
         {:ok, _parent} <- Issues.add_blocker(parent, cto_issue) do
      :ok
    end
  end

  defp add_blockers(_blocked_issue, []), do: :ok

  defp add_blockers(blocked_issue, [blocker | rest]) do
    with {:ok, _} <- Issues.add_blocker(blocked_issue, blocker) do
      add_blockers(blocked_issue, rest)
    end
  end

  defp block_for_swarm(%Issue{} = issue, note) do
    with {:ok, updated} <-
           Issues.update_issue(issue, %{
             status: :blocked,
             assignee_id: issue.assignee_id,
             checkout_run_id: nil,
             checked_out_at: nil
           }),
         {:ok, _comment} <- system_comment(updated, note) do
      {:ok, updated}
    end
  end

  defp persist_launched_state(parent, config, specs, agents, worker_issues, cto_issue) do
    swarm_state =
      config
      |> monitor_state_payload("launched", specs)
      |> Map.put("temporary_agent_ids", Enum.map(agents, & &1.id))
      |> Map.put("worker_issue_ids", Enum.map(worker_issues, & &1.id))
      |> Map.put("cto_issue_id", cto_issue.id)
      |> Map.put(
        "launched_at",
        DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      )

    monitor_state =
      parent.monitor_state
      |> normalize_map()
      |> Map.put("swarm", swarm_state)

    Issues.update_issue(parent, %{monitor_state: monitor_state})
  end

  defp enqueue_worker_wakes(worker_issues) do
    Enum.each(worker_issues, fn issue ->
      _ =
        Cympho.Orchestrator.Dispatcher.enqueue_wake(issue.id, "swarm_worker_created", %{
          "source" => "swarm",
          "parent_issue_id" => issue.parent_id
        })
    end)
  end

  defp maybe_start_agent_heartbeat(%Agent{} = agent) do
    if dispatcher_enabled?() do
      _ = Cympho.AgentHeartbeat.start_for_agent(agent.id)
    end

    :ok
  end

  defp dispatcher_enabled? do
    :cympho
    |> Application.get_env(:orchestrator, [])
    |> Keyword.get(:enabled, true)
  end

  defp monitor_state_payload(config, status, mix \\ nil) do
    mix = mix || config.mix

    %{
      "enabled" => config.enabled,
      "status" => status,
      "topology" => "parallel_workers_cto_synthesis_ceo_handoff",
      "protocol" => protocol_payload(),
      "agent_count" => config.agent_count,
      "mix" =>
        Enum.map(mix, fn spec ->
          %{
            "role" => role_payload(spec.role),
            "harness" => spec.adapter && Atom.to_string(spec.adapter),
            "process_preset" => spec.process_preset,
            "model" => spec.model,
            "reasoning_effort" => spec.reasoning_effort,
            "proxy_profile" => spec.proxy_profile
          }
          |> drop_blank_values()
        end),
      "proxy" =>
        %{
          "enabled" => config.proxy.enabled,
          "mode" => config.proxy.mode,
          "profile" => config.proxy.profile,
          "pool" => config.proxy.pool,
          "profile_ids" => config.proxy.profile_ids
        }
        |> drop_blank_values()
    }
  end

  defp role_payload(nil), do: nil
  defp role_payload(role), do: Atom.to_string(role)

  defp temp_agent_instructions(%Issue{} = parent, spec, index) do
    lens = spec.lens || worker_lens(spec.role, index)

    """
    You are temporary swarm worker #{index} for issue #{parent.identifier || parent.id}.
    Role: #{Agent.role_label(spec.role)}.
    Harness: #{harness_label(spec)}.
    Model: #{spec.model || "runtime default"}.
    Reasoning effort: #{spec.reasoning_effort || "auto"}.
    Lens: #{lens.name}.

    Work independently. Do not wait for, merge with, or defer to other swarm
    workers before producing your packet. Do not implement code or claim
    engineering delivery.

    Produce one concise, evidence-oriented packet for the CTO. The first line
    must be exactly `[delivery]`; do not wrap the packet in a code fence. Use
    these exact headings in order and do not omit any heading:
    [delivery]
    Lens: #{lens.name}
    Recommendation:
    Evidence:
    Assumptions:
    Risks:
    Dissent / alternative:
    Confidence: high|medium|low
    CTO synthesis notes:

    Lens focus: #{lens.focus}
    Challenge: #{lens.challenge}
    """
  end

  defp worker_issue_description(parent, agent, spec, index) do
    lens = spec.lens || worker_lens(spec.role, index)

    """
    Swarm worker #{index} for parent issue #{parent.identifier || parent.id}: #{parent.title}

    Original owner brief:
    #{parent.description || "(no description)"}

    Assigned specialty: #{Agent.role_label(agent.role)}
    Harness: #{harness_label(spec)}
    Model: #{spec.model || "runtime default"}
    Reasoning effort: #{spec.reasoning_effort || "auto"}
    Proxy profile: #{spec.proxy_profile || "none"}
    Lens: #{lens.name}

    Swarm protocol:
    - Independent first pass: do not wait for or copy other worker packets.
    - Evidence over consensus: separate evidence from assumptions.
    - Dissent required: include the strongest counterargument or alternative.
    - CTO gate: deliver only to CTO synthesis; do not hand work directly to CEO.

    Lens focus:
    #{lens.focus}

    Challenge:
    #{lens.challenge}

    Required packet. The first line must be exactly `[delivery]`; do not wrap
    the packet in a code fence. Use these exact headings in order and do not
    omit any heading. After the packet, emit one cympho-actions block:
    ```cympho-actions
    {"actions":[{"type":"swarm_worker_complete","summary":"one sentence summary for CTO synthesis"}]}
    ```

    [delivery]
    Lens: #{lens.name}
    Recommendation:
    Evidence:
    Assumptions:
    Risks:
    Dissent / alternative:
    Confidence: high|medium|low
    CTO synthesis notes:
    """
  end

  defp cto_issue_description(parent, worker_issues, config) do
    worker_list =
      worker_issues
      |> Enum.map_join("\n", fn issue -> "- #{issue.identifier || issue.id}: #{issue.title}" end)

    """
    CTO synthesis for swarm parent issue #{parent.identifier || parent.id}: #{parent.title}

    Wait for the temporary worker packets, then synthesize the operational
    recommendation for the CEO parent issue. Do not concatenate packets; compare
    them, preserve dissent, and name confidence.

    Worker packets:
    #{worker_list}

    Swarm settings:
    - Temporary workers: #{config.agent_count}
    - Proxy mode: #{config.proxy.mode}
    - Proxy profile: #{config.proxy.profile || "none"}
    - Protocol: independent first pass -> CTO synthesis -> CEO handoff

    CTO synthesis protocol:
    - Verify each worker produced a tagged delivery packet or explicit blocker.
    - Map agreements, disagreements, and missing evidence.
    - Resolve contradictions only when evidence supports it; otherwise preserve dissent.
    - State confidence and what would change the recommendation.
    - Recommend the next CEO decision and any follow-up issues.

    Required review:
    [review] Verdict: accepted/request changes/blocked.
    Worker map:
    Agreements:
    Dissent / contradictions:
    Evidence quality:
    Remaining risks:
    Confidence: high|medium|low
    CEO recommendation:
    Restart packet:

    After the review packet, emit exactly one cympho-actions block so this CTO
    synthesis issue can close and unblock the CEO parent:
    ```cympho-actions
    {"actions":[{"type":"approve_issue","notes":"CTO synthesized the swarm worker packets and prepared the CEO recommendation. Evidence inspected: all worker packet comments and blocker state. Restart packet: CEO reviews this synthesis and decides whether to approve, request changes, delegate follow-up, or name a blocker."}]}
    ```
    """
  end

  defp cto_blocker_note(parent, worker_issues) do
    labels =
      worker_issues
      |> Enum.map_join(", ", &(&1.identifier || &1.id))

    "[blocked] Cause: waiting for independent swarm worker packets before CTO synthesis for #{parent.identifier || parent.id}. " <>
      "Attempted fix: launched temporary non-engineering workers #{labels}. " <>
      "Needs: each worker must provide role-specific evidence, assumptions, dissent, risks, confidence, and next-action recommendations. " <>
      "Current state: CTO synthesis is paused behind swarm worker delivery. " <>
      "Next decision: CTO reviews the worker packets and submits a CEO-ready synthesis. " <>
      "Restart packet: inspect the worker child issues, their latest delivery comments, and any attached work products before synthesizing."
  end

  defp parent_blocker_note(cto_issue) do
    "[blocked] Cause: swarm mode delegated first-pass analysis to temporary workers and CTO synthesis. " <>
      "Attempted fix: created CTO synthesis issue #{cto_issue.identifier || cto_issue.id} and blocked this CEO issue on it. " <>
      "Needs: CTO must synthesize completed worker packets into a CEO-ready recommendation while preserving dissent and confidence. " <>
      "Current state: CEO parent issue is paused while swarm delivery flows through CTO. " <>
      "Next decision: CEO reviews CTO synthesis, approves, requests changes, delegates follow-up, or names a blocker. " <>
      "Restart packet: open the CTO synthesis issue, review completed worker packets, and continue from the CTO recommendation."
  end

  defp system_comment(%Issue{} = issue, body) do
    Comments.create_comment(%{
      issue_id: issue.id,
      author_type: "system",
      author_id: "00000000-0000-0000-0000-000000000000",
      body: body
    })
  end

  defp format_event_reason(%Ecto.Changeset{}), do: "validation failed"
  defp format_event_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_event_reason(reason) when is_binary(reason), do: reason
  defp format_event_reason(_reason), do: "unexpected error"

  defp expanded_mix(config) do
    proxy_assignments = randomized_proxy_assignments(config.proxy.pool, config.agent_count)
    runtime_choices = if config.mix == [], do: default_mix(config.agent_count), else: config.mix
    runtime_assignments = randomized_runtime_assignments(runtime_choices, config.agent_count)
    worker_roles = randomized_worker_roles(config.agent_count)

    1..config.agent_count
    |> Enum.map(fn index ->
      spec = Enum.at(runtime_assignments, index - 1)
      role = spec.role || Enum.at(worker_roles, index - 1)

      spec
      |> Map.put(:role, role)
      |> Map.put(:lens, worker_lens(role, index))
      |> Map.put(:proxy_profile, spec.proxy_profile || Enum.at(proxy_assignments, index - 1))
    end)
  end

  defp randomized_runtime_assignments(runtime_choices, count) do
    runtime_choices
    |> Enum.shuffle()
    |> Stream.cycle()
    |> Enum.take(count)
  end

  defp randomized_worker_roles(count) do
    @allowed_worker_roles
    |> Enum.shuffle()
    |> Stream.cycle()
    |> Enum.take(count)
  end

  defp randomized_proxy_assignments([], _count), do: []

  defp randomized_proxy_assignments(pool, count) do
    pool
    |> Enum.shuffle()
    |> Stream.cycle()
    |> Enum.take(count)
  end

  defp protocol_payload do
    %{
      "version" => @protocol_version,
      "topology" => "parallel_workers_cto_synthesis_ceo_handoff",
      "worker_contract" => "independent_delivery_packet_v1",
      "synthesis_contract" => "cto_synthesis_review_v1",
      "rules" =>
        Enum.map(@protocol_rules, fn {key, label} ->
          %{"key" => Atom.to_string(key), "label" => label}
        end)
    }
  end

  defp worker_lens(role, index) do
    role_lens =
      Map.get(@role_lenses, role, %{
        name: Agent.role_label(role),
        focus: "Role-specific assumptions, risks, evidence, and next decision."
      })

    challenge = Enum.at(@challenge_lenses, rem(index - 1, length(@challenge_lenses)))

    role_lens
    |> Map.put(:challenge, challenge)
  end

  defp lens_payload(nil), do: nil

  defp lens_payload(%{name: name, focus: focus, challenge: challenge}) do
    %{
      "name" => name,
      "focus" => focus,
      "challenge" => challenge
    }
  end

  defp lens_payload(_), do: nil

  defp raw_swarm_params(attrs) when is_map(attrs) do
    raw =
      Map.get(attrs, "swarm") ||
        Map.get(attrs, :swarm) ||
        %{}

    raw =
      if raw == %{} do
        %{
          "enabled" => get_param(attrs, :swarm_enabled) || get_param(attrs, :swarm_mode),
          "agent_count" => get_param(attrs, :swarm_agent_count),
          "mix_rows" => get_param(attrs, :swarm_mix_rows),
          "mix" => get_param(attrs, :swarm_mix),
          "proxy_mode" => get_param(attrs, :swarm_proxy_mode),
          "proxy_enabled" => get_param(attrs, :swarm_proxy_enabled),
          "proxy_profile" => get_param(attrs, :swarm_proxy_profile),
          "proxy_profile_ids" => get_param(attrs, :swarm_proxy_profile_ids),
          "proxy_pool" => get_param(attrs, :swarm_proxy_pool)
        }
      else
        normalize_map(raw)
      end

    raw
  end

  defp raw_swarm_params(_attrs), do: %{}

  defp authorized?(attrs) do
    company_id = get_param(attrs, :company_id)
    user_id = swarm_actor_user_id(attrs)

    cond do
      not is_binary(company_id) ->
        true

      is_nil(user_id) ->
        true

      Companies.admin?(user_id, company_id) or Companies.is_board_member?(user_id, company_id) ->
        true

      true ->
        false
    end
  end

  defp swarm_actor_user_id(attrs) do
    get_param(attrs, :created_by_user_id) ||
      if get_param(attrs, :actor_type) == "user", do: get_param(attrs, :actor_id)
  end

  defp raw_enabled?(%{} = raw) do
    raw
    |> get_param(:enabled)
    |> truthy?()
  end

  defp raw_enabled?(_), do: false

  defp raw_agent_count(raw) do
    raw
    |> get_param(:agent_count)
    |> parse_int(@default_agent_count)
    |> min(@max_agent_count)
    |> max(1)
  end

  defp raw_proxy(raw, attrs) do
    nested_proxy = raw |> get_param(:proxy) |> normalize_map()
    legacy_enabled? = truthy?(get_param(raw, :proxy_enabled) || get_param(nested_proxy, :enabled))

    mode =
      normalize_proxy_mode(get_param(raw, :proxy_mode) || get_param(nested_proxy, :mode)) ||
        if(legacy_enabled?, do: "manual", else: "none")

    profile =
      normalize_proxy_profile(get_param(raw, :proxy_profile)) ||
        normalize_proxy_profile(get_param(nested_proxy, :profile))

    profile_ids =
      normalize_id_list(
        get_param(raw, :proxy_profile_ids) || get_param(nested_proxy, :profile_ids)
      )

    saved_pool =
      attrs
      |> get_param(:company_id)
      |> saved_proxy_pool(mode, profile_ids)

    pool =
      [
        saved_pool,
        profile,
        normalize_proxy_pool(get_param(raw, :proxy_pool)),
        normalize_proxy_pool(get_param(nested_proxy, :pool)),
        normalize_proxy_pool(get_param(nested_proxy, :profiles))
      ]
      |> List.flatten()
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    %{
      enabled: mode != "none" and pool != [],
      mode: if(mode != "none" and pool != [], do: mode, else: "none"),
      profile: if(mode != "none" and pool != [], do: profile || List.first(pool), else: nil),
      pool: if(mode != "none", do: pool, else: []),
      profile_ids: if(mode in ["random", "selected"], do: profile_ids, else: [])
    }
  end

  defp raw_mix(raw, agent_count) do
    case normalize_mix_rows(get_param(raw, :mix_rows)) do
      [] ->
        raw
        |> get_param(:mix)
        |> normalize_mix()
        |> case do
          [] -> default_mix(agent_count)
          mix -> mix
        end

      mix ->
        mix
    end
  end

  defp default_mix(agent_count) do
    [
      %{
        role: nil,
        adapter: Cympho.Adapters.Registry.default_adapter(),
        process_preset: nil,
        model: nil,
        reasoning_effort: "medium",
        proxy_profile: nil
      },
      %{
        role: nil,
        adapter: :codex,
        process_preset: nil,
        model: "gpt-5.3-high-fast",
        reasoning_effort: "high",
        proxy_profile: nil
      },
      %{
        role: nil,
        adapter: :openai_chat,
        process_preset: nil,
        model: "gpt-5.4-mini",
        reasoning_effort: "medium",
        proxy_profile: nil
      }
    ]
    |> Stream.cycle()
    |> Enum.take(min(agent_count, length(@default_worker_roles)))
  end

  defp normalize_mix(nil), do: []
  defp normalize_mix(""), do: []

  defp normalize_mix(mix) when is_binary(mix) do
    mix
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&parse_mix_line/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_mix(mix) when is_list(mix) do
    mix
    |> Enum.map(&parse_mix_entry/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_mix(_mix), do: []

  defp normalize_mix_rows(nil), do: []
  defp normalize_mix_rows(""), do: []

  defp normalize_mix_rows(rows) when is_map(rows) do
    rows
    |> Enum.sort_by(fn {index, _row} -> parse_int(index, 0) end)
    |> Enum.map(fn {_index, row} -> normalize_map(row) end)
    |> Enum.filter(&truthy?(get_param(&1, :enabled)))
    |> Enum.map(&parse_mix_entry/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_mix_rows(rows) when is_list(rows) do
    rows
    |> Enum.map(&normalize_map/1)
    |> Enum.filter(&truthy?(get_param(&1, :enabled)))
    |> Enum.map(&parse_mix_entry/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_mix_rows(_rows), do: []

  defp parse_mix_line(line) do
    line
    |> String.split(~r/\s*[|,]\s*/, parts: 5, trim: true)
    |> case do
      [first] ->
        if worker_role?(first) do
          parse_mix_entry(%{"role" => first})
        else
          parse_mix_entry(%{"harness" => first})
        end

      [first, second] ->
        if worker_role?(first) do
          parse_mix_entry(%{"role" => first, "harness" => second})
        else
          parse_mix_entry(%{"harness" => first, "model" => second})
        end

      [first, second, third] ->
        if worker_role?(first) do
          parse_mix_entry(%{"role" => first, "harness" => second, "model" => third})
        else
          if normalize_reasoning_effort(third) do
            parse_mix_entry(%{
              "harness" => first,
              "model" => second,
              "reasoning_effort" => third
            })
          else
            parse_mix_entry(%{"harness" => first, "model" => second, "proxy_profile" => third})
          end
        end

      [first, second, third, fourth] ->
        if worker_role?(first) do
          if normalize_reasoning_effort(fourth) do
            parse_mix_entry(%{
              "role" => first,
              "harness" => second,
              "model" => third,
              "reasoning_effort" => fourth
            })
          else
            parse_mix_entry(%{
              "role" => first,
              "harness" => second,
              "model" => third,
              "proxy_profile" => fourth
            })
          end
        else
          parse_mix_entry(%{
            "harness" => first,
            "model" => second,
            "reasoning_effort" => third,
            "proxy_profile" => fourth
          })
        end

      [role, harness, model, reasoning_effort, entry_proxy] ->
        parse_mix_entry(%{
          "role" => role,
          "harness" => harness,
          "model" => model,
          "reasoning_effort" => reasoning_effort,
          "proxy_profile" => entry_proxy
        })

      _ ->
        nil
    end
  end

  defp parse_mix_entry(%{} = entry) do
    role =
      entry
      |> get_param(:role)
      |> normalize_worker_role_optional()

    if role != :invalid do
      {adapter, process_preset} =
        normalize_harness(
          get_param(entry, :harness) || get_param(entry, :adapter),
          get_param(entry, :process_preset) || get_param(entry, :preset)
        )

      %{
        role: role,
        adapter: adapter,
        process_preset: process_preset,
        model: normalize_optional_string(get_param(entry, :model), 120),
        reasoning_effort:
          normalize_reasoning_effort(
            get_param(entry, :reasoning_effort) || get_param(entry, :reasoning)
          ),
        proxy_profile: normalize_proxy_profile(get_param(entry, :proxy_profile))
      }
    end
  end

  defp parse_mix_entry(_entry), do: nil

  defp normalize_worker_role(role) do
    case Agent.normalize_role(role) do
      role when role in @allowed_worker_roles -> {:ok, role}
      _ -> :error
    end
  end

  defp normalize_worker_role_optional(value) when value in [nil, ""], do: nil

  defp normalize_worker_role_optional(value) do
    case normalize_worker_role(value) do
      {:ok, role} -> role
      :error -> :invalid
    end
  end

  defp worker_role?(value) do
    match?({:ok, _role}, normalize_worker_role(value))
  end

  defp normalize_harness(harness, process_preset) do
    normalized_preset = normalize_process_preset(process_preset)

    case normalize_harness_value(harness) do
      {:process, preset} ->
        {:process, preset || normalized_preset}

      {:adapter, :process} ->
        {:process, normalized_preset}

      {:adapter, adapter} ->
        {adapter, nil}

      :unknown ->
        case normalized_preset do
          nil -> {Cympho.Adapters.Registry.default_adapter(), nil}
          preset -> {:process, preset}
        end
    end
  end

  defp normalize_harness_value(harness) when harness in [nil, ""], do: :unknown

  defp normalize_harness_value(harness) do
    normalized =
      harness
      |> to_string()
      |> String.trim()
      |> String.downcase()
      |> String.replace("-", "_")

    cond do
      String.starts_with?(normalized, "process:") ->
        preset =
          normalized
          |> String.replace_prefix("process:", "")
          |> normalize_process_preset()

        {:process, preset}

      adapter = Enum.find(Agent.adapter_options(), &(Atom.to_string(&1) == normalized)) ->
        {:adapter, adapter}

      preset = normalize_process_preset(normalized) ->
        {:process, preset}

      true ->
        :unknown
    end
  end

  defp normalize_process_preset(value) when value in [nil, ""], do: nil

  defp normalize_process_preset(value) do
    normalized =
      value
      |> to_string()
      |> String.trim()
      |> String.downcase()
      |> String.replace("-", "_")
      |> process_preset_alias()

    if normalized in process_preset_values(), do: normalized
  end

  defp process_preset_alias("agy"), do: "antigravity"
  defp process_preset_alias("kimi"), do: "kimi_code"
  defp process_preset_alias("kimi_cli"), do: "kimi_code"
  defp process_preset_alias("kimi_code_cli"), do: "kimi_code"
  defp process_preset_alias("open_code"), do: "opencode"
  defp process_preset_alias(value), do: value

  defp process_preset_values do
    RuntimeOptions.process_preset_options()
    |> Enum.map(fn {_label, value} -> value end)
    |> Enum.reject(&(&1 == "custom"))
  end

  defp harness_label(%{adapter: :process, process_preset: preset}) when is_binary(preset),
    do: "process:#{preset}"

  defp harness_label(%{adapter: adapter}) when not is_nil(adapter), do: Atom.to_string(adapter)
  defp harness_label(_), do: Atom.to_string(Cympho.Adapters.Registry.default_adapter())

  defp normalize_reasoning_effort(value) do
    value
    |> normalize_optional_string(40)
    |> case do
      nil ->
        nil

      effort ->
        effort =
          effort
          |> String.downcase()
          |> String.replace("-", "_")

        if effort in @reasoning_efforts, do: effort, else: nil
    end
  end

  defp normalize_proxy_mode(value) when is_binary(value) do
    value =
      value
      |> String.trim()
      |> String.downcase()

    if value in ["none", "manual", "random", "selected"], do: value
  end

  defp normalize_proxy_mode(_), do: nil

  defp saved_proxy_pool(company_id, mode, profile_ids) when is_binary(company_id) do
    profiles =
      case mode do
        "random" -> Proxies.list_proxy_profiles(company_id)
        "selected" -> Proxies.list_proxy_profiles_by_ids(company_id, profile_ids)
        _ -> []
      end

    Enum.map(profiles, &Proxies.profile_reference/1)
  end

  defp saved_proxy_pool(_company_id, _mode, _profile_ids), do: []

  defp normalize_id_list(nil), do: []

  defp normalize_id_list(value) when is_binary(value) do
    value
    |> String.split(~r/[\n,]+/)
    |> Enum.map(&normalize_optional_string(&1, 64))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_id_list(values) when is_list(values) do
    values
    |> Enum.map(&normalize_optional_string(&1, 64))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_id_list(_), do: []

  defp normalize_proxy_profile(value) do
    value
    |> normalize_optional_string(120)
    |> case do
      nil ->
        nil

      profile ->
        if Regex.match?(~r/^[a-z][a-z0-9+.-]*:\/\//i, profile) do
          nil
        else
          profile
        end
    end
  end

  defp normalize_proxy_pool(nil), do: []
  defp normalize_proxy_pool(""), do: []

  defp normalize_proxy_pool(value) when is_binary(value) do
    value
    |> String.split(~r/[\n,]+/)
    |> Enum.map(&normalize_proxy_profile/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.take(@max_agent_count)
  end

  defp normalize_proxy_pool(values) when is_list(values) do
    values
    |> Enum.map(&normalize_proxy_profile/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.take(@max_agent_count)
  end

  defp normalize_proxy_pool(_), do: []

  defp normalize_optional_string(value, max_length) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      value -> String.slice(value, 0, max_length)
    end
  end

  defp normalize_optional_string(_value, _max_length), do: nil

  defp parse_int(value, _default) when is_integer(value), do: value

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _} -> parsed
      :error -> default
    end
  end

  defp parse_int(_value, default), do: default

  defp truthy?(value) when value in [true, "true", "on", "1", 1], do: true
  defp truthy?(_), do: false

  defp get_param(attrs, key) when is_atom(key) and is_map(attrs) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end

  defp put_param(attrs, key, value) when is_atom(key) do
    Map.put(attrs, preferred_param_key(attrs, key), value)
  end

  defp preferred_param_key(attrs, key) when is_atom(key) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(attrs, string_key) -> string_key
      Enum.any?(Map.keys(attrs), &is_binary/1) -> string_key
      true -> key
    end
  end

  defp normalize_map(%{} = map), do: map
  defp normalize_map(_), do: %{}

  defp drop_blank_values(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end
end
