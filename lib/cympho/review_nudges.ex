defmodule Cympho.ReviewNudges do
  @moduledoc """
  Plans and queues targeted follow-up nudges for review-gate blockers.

  A nudge is intentionally explicit: it assigns the issue to the right agent,
  creates an inbox item, enqueues a manual wake, and leaves a system comment so
  humans can audit why the agent was poked. Related blockers for the same
  agent and issue are grouped into one nudge to avoid noisy duplicate wakeups.

  Reconciliation is intentionally idempotent. It only consumes active
  review-nudge wakes whose blocker keys are now satisfied; once consumed, later
  calls ignore the wake and do not write another "satisfied" comment.
  """

  alias Cympho.Agents
  alias Cympho.Agents.Agent
  alias Cympho.AgentPromptContract
  alias Cympho.Comments
  alias Cympho.HeartbeatEngine
  alias Cympho.IssueDigest
  alias Cympho.IssueMemory
  alias Cympho.Inbox
  alias Cympho.Issues
  alias Cympho.Issues.Issue
  alias Cympho.PullRequestContract
  alias Cympho.WorkProducts
  alias Cympho.Wakes

  @active_wake_statuses ~w(pending running)

  def plan(%Issue{} = issue, blockers, opts \\ []) do
    agents = Keyword.get(opts, :agents, [])
    child_issues = Keyword.get(opts, :child_issues, [])
    wakes = Keyword.get_lazy(opts, :wakes, fn -> active_review_wakes(issue, child_issues) end)

    blockers
    |> List.wrap()
    |> Enum.flat_map(&nudge_for_blocker(issue, &1, agents, child_issues))
    |> group_nudges()
    |> Enum.map(&annotate_lifecycle(&1, wakes))
  end

  def plan_contract_gaps(%Issue{} = issue, opts \\ []) do
    agents = agents_for_issue(issue, opts)
    runs = Keyword.get_lazy(opts, :runs, fn -> HeartbeatEngine.list_runs_for_issue(issue.id) end)

    work_products =
      Keyword.get_lazy(opts, :work_products, fn -> WorkProducts.list_work_products(issue.id) end)

    child_issues =
      Keyword.get_lazy(opts, :child_issues, fn -> Issues.list_child_issues(issue.id) end)

    wakes = Keyword.get_lazy(opts, :wakes, fn -> active_review_wakes(issue, child_issues) end)

    digest = IssueDigest.build(issue, runs, work_products, child_issues, agents)

    memory_contracts = IssueMemory.contract_gaps(issue, runs, work_products, child_issues, agents)

    (digest.completion_contract ++ memory_contracts ++ pr_quality_contracts(issue))
    |> Enum.filter(&(&1.status in [:missing, :attention]))
    |> Enum.map(&contract_nudge(issue, &1, agents))
    |> group_nudges()
    |> Enum.map(&annotate_lifecycle(&1, wakes))
  end

  def execute_contract_gap(issue_or_id, contract_key, opts \\ [])

  def execute_contract_gap(issue_id, contract_key, opts) when is_binary(issue_id) do
    case Issues.get_issue(issue_id) do
      {:ok, issue} -> execute_contract_gap(issue, contract_key, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  def execute_contract_gap(%Issue{} = issue, contract_key, opts) do
    actor = Keyword.get(opts, :actor)
    normalized_key = normalize_contract_key(contract_key)

    issue
    |> plan_contract_gaps(opts)
    |> Enum.find(fn nudge ->
      nudge.contract_key == normalized_key or nudge.key == contract_key or
        contract_key in nudge.legacy_keys
    end)
    |> case do
      nil ->
        {:error, :nudge_not_found}

      %{agent_id: nil} ->
        {:error, :no_target_agent}

      %{queued?: true} = nudge ->
        {:ok, %{nudge | already_queued?: true}}

      nudge ->
        queue_nudge(issue, nudge, actor)
    end
  end

  def execute(%Issue{} = issue, nudge_key, opts \\ []) when is_binary(nudge_key) do
    actor = Keyword.get(opts, :actor)

    issue
    |> plan(Keyword.get(opts, :blockers, []), opts)
    |> Enum.find(&(&1.key == nudge_key or nudge_key in &1.legacy_keys))
    |> case do
      nil ->
        {:error, :nudge_not_found}

      %{agent_id: nil} ->
        {:error, :no_target_agent}

      %{queued?: true} = nudge ->
        {:ok, %{nudge | already_queued?: true}}

      nudge ->
        queue_nudge(issue, nudge, actor)
    end
  end

  def reconcile_issue(issue_or_id, opts \\ [])

  def reconcile_issue(nil, _opts), do: {:ok, []}

  def reconcile_issue(issue_id, opts) when is_binary(issue_id) do
    case Issues.get_issue(issue_id) do
      {:ok, issue} -> reconcile_issue(issue, opts)
      {:error, _reason} -> {:ok, []}
    end
  end

  def reconcile_issue(%Issue{} = issue, opts) do
    with {:ok, issue} <- reload_issue(issue) do
      active_wakes = Wakes.list_review_nudges([issue.id])

      if active_wakes == [] do
        {:ok, []}
      else
        active_blocker_keys = current_blocker_keys(issue)

        cleared =
          active_wakes
          |> Enum.filter(&wake_satisfied?(&1, issue, active_blocker_keys))
          |> Enum.flat_map(&consume_satisfied_wake/1)

        maybe_write_clear_comment(issue, cleared, opts)
        {:ok, cleared}
      end
    else
      {:error, _reason} -> {:ok, []}
    end
  end

  def cleared(%Issue{} = issue, opts \\ []) do
    child_issues = Keyword.get(opts, :child_issues, [])

    [issue.id | Enum.map(child_issues, & &1.id)]
    |> Wakes.list_review_nudges(statuses: ["consumed"])
    |> Enum.map(&cleared_nudge_map/1)
  end

  defp nudge_for_blocker(issue, %{key: key} = blocker, agents, _child_issues)
       when key in [
              :agent_note,
              :delivery_comment,
              :work_product,
              :runtime_verification,
              :code_reference
            ] do
    agent = delivery_agent(issue, agents)
    [build_nudge(issue, blocker, agent, :delivery)]
  end

  defp nudge_for_blocker(issue, %{key: :review_decision} = blocker, agents, _child_issues) do
    agent = role_agent(agents, :cto) || role_agent(agents, :ceo)
    [build_nudge(issue, blocker, agent, :cto_review)]
  end

  defp nudge_for_blocker(issue, %{key: key} = blocker, agents, _child_issues)
       when key in [:owner_summary, :ceo_owner_update] do
    agent = role_agent(agents, :ceo)
    [build_nudge(issue, blocker, agent, :ceo_update)]
  end

  defp nudge_for_blocker(_issue, %{key: :child_work} = blocker, agents, child_issues) do
    child_issues
    |> Enum.filter(&(&1.status not in [:done, :cancelled]))
    |> Enum.map(fn child ->
      build_nudge(child, blocker, child_agent(child, agents), :child_work)
    end)
  end

  defp nudge_for_blocker(issue, blocker, agents, _child_issues) do
    agent = delivery_agent(issue, agents)
    [build_nudge(issue, blocker, agent, :general)]
  end

  defp build_nudge(issue, blocker, agent, type) do
    prompt = nudge_prompt(type, issue, [blocker])
    agent_id = agent && agent.id

    %{
      key: nudge_key(type, issue.id, agent_id),
      legacy_keys: [legacy_nudge_key(blocker.key, issue.id)],
      type: type,
      blocker_key: blocker.key,
      blocker_keys: [blocker.key],
      blocker_label: blocker.label,
      blocker_labels: [blocker.label],
      blockers: [blocker],
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      issue_title: issue.title,
      agent_id: agent_id,
      agent_name: agent_name(agent),
      agent_role: agent_role(agent, type),
      prompt: prompt,
      button_label: button_label(type),
      summary: summary(type, [blocker]),
      status: :ready,
      status_label: "Ready",
      queued?: false,
      already_queued?: false,
      wake_id: nil,
      wake_status: nil,
      enabled?: not is_nil(agent)
    }
  end

  defp contract_nudge(issue, contract, agents) do
    type = contract_nudge_type(contract.key)
    agent = contract_agent(issue, contract.key, agents)
    agent_id = agent && agent.id
    blocker_key = contract_blocker_key(contract.key)
    blocker_label = contract.label

    %{
      key: nudge_key(type, issue.id, agent_id),
      legacy_keys: [legacy_nudge_key(blocker_key, issue.id)],
      type: type,
      contract_key: contract.key,
      blocker_key: blocker_key,
      blocker_keys: [blocker_key],
      blocker_label: blocker_label,
      blocker_labels: [blocker_label],
      blockers: [
        %{
          key: blocker_key,
          label: blocker_label,
          prompt: contract.prompt
        }
      ],
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      issue_title: issue.title,
      agent_id: agent_id,
      agent_name: agent_name(agent),
      agent_role: agent_role(agent, type),
      prompt: contract_nudge_prompt(issue, contract),
      button_label: button_label(type),
      summary: contract_nudge_summary(contract),
      status: :ready,
      status_label: "Ready",
      queued?: false,
      already_queued?: false,
      wake_id: nil,
      wake_status: nil,
      enabled?: not is_nil(agent)
    }
  end

  defp group_nudges(nudges) do
    nudges
    |> Enum.group_by(&{&1.type, &1.issue_id, &1.agent_id})
    |> Enum.map(fn {_key, grouped} -> combine_nudges(grouped) end)
  end

  defp combine_nudges([first | _] = nudges) do
    blockers =
      nudges
      |> Enum.flat_map(& &1.blockers)
      |> Enum.uniq_by(& &1.key)

    blocker_keys = Enum.map(blockers, & &1.key)
    blocker_labels = Enum.map(blockers, & &1.label)

    %{
      first
      | key: nudge_key(first.type, first.issue_id, first.agent_id),
        legacy_keys: Enum.map(blockers, &legacy_nudge_key(&1.key, first.issue_id)),
        blocker_key: List.first(blocker_keys),
        blocker_keys: blocker_keys,
        blocker_label: Enum.join(blocker_labels, ", "),
        blocker_labels: blocker_labels,
        blockers: blockers,
        prompt: nudge_prompt(first.type, first, blockers),
        summary: summary(first.type, blockers)
    }
  end

  defp annotate_lifecycle(nudge, wakes) do
    wake = Enum.find(wakes, &wake_matches?(&1, nudge))

    cond do
      is_nil(nudge.agent_id) ->
        %{nudge | status: :unrouted, status_label: "No agent", enabled?: false}

      wake && wake.status in @active_wake_statuses ->
        %{
          nudge
          | status: :queued,
            status_label: String.capitalize(wake.status),
            queued?: true,
            wake_id: wake.id,
            wake_status: wake.status,
            enabled?: false,
            button_label: "Queued"
        }

      true ->
        nudge
    end
  end

  defp wake_matches?(wake, nudge) do
    metadata = wake.metadata || %{}

    metadata["nudge_group_key"] == nudge.key ||
      metadata["nudge_key"] in nudge.legacy_keys ||
      (wake.agent_id == nudge.agent_id && wake.issue_id == nudge.issue_id &&
         intersects?(
           List.wrap(metadata["blocker_keys"]),
           Enum.map(nudge.blocker_keys, &to_string/1)
         ))
  end

  defp intersects?(left, right), do: Enum.any?(left, &(&1 in right))

  defp active_review_wakes(issue, child_issues) do
    issue_ids =
      [issue.id | Enum.map(child_issues, & &1.id)]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    Wakes.list_review_nudges(issue_ids)
  end

  defp reload_issue(%Issue{id: id}), do: Issues.get_issue(id)

  defp current_blocker_keys(issue) do
    runs = HeartbeatEngine.list_runs_for_issue(issue.id)
    work_products = WorkProducts.list_work_products(issue.id)
    child_issues = Issues.list_child_issues(issue.id)

    digest = IssueDigest.build(issue, runs, work_products, child_issues)

    review_keys =
      digest
      |> get_in([:review_readiness, :blockers])
      |> List.wrap()
      |> Enum.map(&(&1.key |> to_string()))

    contract_keys =
      digest
      |> Map.get(:completion_contract, [])
      |> Enum.filter(&(&1.status in [:missing, :attention]))
      |> Enum.map(&(&1.key |> contract_blocker_key() |> to_string()))

    pr_quality_keys =
      issue
      |> pr_quality_contracts()
      |> Enum.map(&(&1.key |> contract_blocker_key() |> to_string()))

    memory_keys =
      issue
      |> IssueMemory.contract_gaps(runs, work_products, child_issues)
      |> Enum.map(&(&1.key |> contract_blocker_key() |> to_string()))

    MapSet.new(review_keys ++ contract_keys ++ memory_keys ++ pr_quality_keys)
  end

  defp wake_satisfied?(wake, issue, active_blocker_keys) do
    keys = wake_blocker_keys(wake)

    cond do
      keys == [] ->
        false

      "child_work" in keys and issue.status in [:done, :cancelled] ->
        true

      true ->
        Enum.all?(keys, &(not MapSet.member?(active_blocker_keys, &1)))
    end
  end

  defp consume_satisfied_wake(wake) do
    case Wakes.consume_review_nudge(wake) do
      {:ok, consumed} ->
        :ok = Inbox.notify_entry_updated(wake.issue_id, wake.agent_id)
        [consumed]

      {:error, _reason} ->
        []
    end
  end

  defp maybe_write_clear_comment(_issue, [], _opts), do: :ok

  defp maybe_write_clear_comment(issue, cleared, opts) do
    if Keyword.get(opts, :comment?, true) do
      labels =
        cleared
        |> Enum.flat_map(&List.wrap((&1.metadata || %{})["blocker_labels"]))
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.uniq()

      Comments.create_comment(%{
        issue_id: issue.id,
        author_type: "system",
        author_id: "review_nudge",
        body:
          "Auto-nudge satisfied: #{labels_sentence_from_strings(labels)}. " <>
            "The matching inbox marker was cleared."
      })
    else
      :ok
    end
  end

  defp cleared_nudge_map(wake) do
    metadata = wake.metadata || %{}

    %{
      wake_id: wake.id,
      agent_name: agent_name(wake.agent),
      summary: metadata["summary"] || "Review nudge satisfied",
      blocker_labels: List.wrap(metadata["blocker_labels"]),
      cleared_at: wake.consumed_at || wake.inserted_at
    }
  end

  defp wake_blocker_keys(wake) do
    metadata = wake.metadata || %{}

    metadata
    |> Map.get("blocker_keys", [metadata["blocker_key"]])
    |> List.wrap()
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
  end

  defp queue_nudge(_root_issue, nudge, actor) do
    with {:ok, issue} <- Issues.get_issue(nudge.issue_id),
         {:ok, issue} <- assign_issue(issue, nudge),
         {:ok, _inbox} <- Inbox.ensure_inbox_entry(issue.id, nudge.agent_id, refresh?: true),
         {:ok, wake} <- wake_agent(issue, nudge, actor),
         {:ok, _comment} <- nudge_comment(issue, nudge, actor) do
      {:ok,
       %{nudge | status: :queued, status_label: String.capitalize(wake.status), wake_id: wake.id}}
    end
  end

  defp assign_issue(issue, nudge) do
    if issue.assignee_id == nudge.agent_id and issue.assigned_role == nudge.agent_role do
      {:ok, issue}
    else
      Issues.update_issue(issue, %{
        assignee_id: nudge.agent_id,
        assigned_role: nudge.agent_role
      })
    end
  end

  defp wake_agent(issue, nudge, actor) do
    {actor_type, actor_id} = actor_tuple(actor)

    Wakes.do_wake_agent(
      nudge.agent_id,
      issue.id,
      "manual_dispatch",
      actor_type,
      actor_id,
      %{
        "source" => "review_nudge",
        "nudge_group_key" => nudge.key,
        "nudge_key" => List.first(nudge.legacy_keys),
        "blocker_key" => to_string(nudge.blocker_key),
        "blocker_keys" => Enum.map(nudge.blocker_keys, &to_string/1),
        "blocker_labels" => nudge.blocker_labels,
        "summary" => nudge.summary,
        "prompt" => nudge.prompt,
        "contract_key" => Map.get(nudge, :contract_key) && to_string(nudge.contract_key)
      }
    )
  end

  defp nudge_comment(issue, nudge, actor) do
    {_actor_type, actor_id} = actor_tuple(actor)

    Comments.create_comment(%{
      issue_id: issue.id,
      author_type: "system",
      author_id: actor_id || "review_nudge",
      body:
        "Auto-nudge queued for #{nudge.agent_name}: #{Enum.join(nudge.blocker_labels, ", ")}. " <>
          "#{nudge.prompt} This issue is now in #{nudge.agent_name}'s inbox."
    })
  end

  defp actor_tuple(%{id: id}) when is_binary(id), do: {"user", id}
  defp actor_tuple(_), do: {"system", "review_nudge"}

  defp delivery_agent(%{assignee: %Agent{} = agent}, _agents), do: agent

  defp delivery_agent(%{assignee_id: assignee_id}, agents) when is_binary(assignee_id) do
    Enum.find(agents, &(&1.id == assignee_id))
  end

  defp delivery_agent(%{assigned_role: role}, agents) when role not in [nil, ""] do
    role_agent(agents, role_to_atom(role))
  end

  defp delivery_agent(_issue, agents) do
    role_agent(agents, :engineer) || role_agent(agents, :product_manager) ||
      role_agent(agents, :designer)
  end

  defp child_agent(%{assignee: %Agent{} = agent}, _agents), do: agent

  defp child_agent(%{assignee_id: assignee_id}, agents) when is_binary(assignee_id) do
    Enum.find(agents, &(&1.id == assignee_id))
  end

  defp child_agent(%{assigned_role: role}, agents) when role not in [nil, ""] do
    role_agent(agents, role_to_atom(role))
  end

  defp child_agent(_child, agents), do: role_agent(agents, :engineer)

  defp contract_agent(issue, :delivery_contract, agents), do: delivery_agent(issue, agents)

  defp contract_agent(_issue, :review_contract, agents) do
    role_agent(agents, :cto) || role_agent(agents, :ceo)
  end

  defp contract_agent(_issue, :owner_contract, agents), do: role_agent(agents, :ceo)
  defp contract_agent(issue, :memory_summary, agents), do: delivery_agent(issue, agents)
  defp contract_agent(issue, :pr_quality, agents), do: delivery_agent(issue, agents)
  defp contract_agent(issue, _key, agents), do: delivery_agent(issue, agents)

  defp agents_for_issue(%Issue{company_id: company_id}, opts) do
    case Keyword.fetch(opts, :agents) do
      {:ok, agents} ->
        agents

      :error when is_binary(company_id) ->
        Agents.list_agents_by_company(company_id)

      :error ->
        []
    end
  end

  defp agents_for_issue(_issue, _opts), do: []

  defp role_agent(_agents, nil), do: nil

  defp role_agent(agents, role) do
    Enum.find(agents, &(&1.role == role))
  end

  defp role_to_atom(role) when is_atom(role), do: role

  defp role_to_atom(role) do
    role
    |> to_string()
    |> String.to_existing_atom()
  rescue
    ArgumentError -> nil
  end

  defp nudge_key(type, issue_id, agent_id) do
    "#{type}:#{issue_id}:#{agent_id || "unassigned"}"
  end

  defp legacy_nudge_key(blocker_key, issue_id), do: "#{blocker_key}:#{issue_id}"

  defp normalize_contract_key(key) when is_atom(key), do: key

  defp normalize_contract_key(key) do
    key
    |> to_string()
    |> String.to_existing_atom()
  rescue
    ArgumentError -> nil
  end

  defp contract_nudge_type(:delivery_contract), do: :contract_delivery
  defp contract_nudge_type(:review_contract), do: :contract_review
  defp contract_nudge_type(:owner_contract), do: :contract_owner
  defp contract_nudge_type(:memory_summary), do: :memory_summary
  defp contract_nudge_type(:pr_quality), do: :pr_quality
  defp contract_nudge_type(_key), do: :contract_gap

  defp contract_blocker_key(:delivery_contract), do: :contract_delivery_contract
  defp contract_blocker_key(:review_contract), do: :contract_review_contract
  defp contract_blocker_key(:owner_contract), do: :contract_owner_contract
  defp contract_blocker_key(:memory_summary), do: :memory_summary
  defp contract_blocker_key(:pr_quality), do: :pr_quality
  defp contract_blocker_key(key), do: normalize_contract_key(key) || :contract_gap

  defp nudge_prompt(:delivery, issue, blockers) do
    "#{issue_label(issue)} needs delivery evidence for #{labels_sentence(blockers)}. " <>
      "Add `#{AgentPromptContract.required_template(:engineer)}`, attach any missing artifact or PR, then submit for review."
  end

  defp nudge_prompt(:cto_review, issue, _blockers) do
    "#{issue_label(issue)} is waiting for CTO review. Inspect attached evidence, child issues, and verification, then leave `#{AgentPromptContract.required_template(:cto)}`."
  end

  defp nudge_prompt(:ceo_update, issue, _blockers) do
    "#{issue_label(issue)} is waiting for the owner update. Draft `#{AgentPromptContract.required_template(:ceo)}` using the child issue rollup and CTO review."
  end

  defp nudge_prompt(:child_work, issue, blockers) do
    "#{issue_label(issue)} is blocking its parent: #{prompts_sentence(blockers)} Finish the child issue or leave `[blocked]` with the exact blocker and next action."
  end

  defp nudge_prompt(:pr_quality, issue, blockers) do
    "#{issue_label(issue)} has a PR quality failure. #{prompts_sentence(blockers)}"
  end

  defp nudge_prompt(_type, issue, blockers) do
    "#{issue_label(issue)} needs action for #{labels_sentence(blockers)}: #{prompts_sentence(blockers)}"
  end

  defp contract_nudge_prompt(issue, %{key: :pr_quality} = contract) do
    pr_quality = pr_quality_payload(issue) || %{"gaps" => Map.get(contract, :pr_gaps, [])}
    repair_packet = PullRequestContract.repair_packet_markdown(issue, pr_quality)

    details =
      contract
      |> Map.get(:pr_gaps, [])
      |> Enum.map(&(&1["detail"] || &1[:detail]))
      |> Enum.reject(&(&1 in [nil, ""]))
      |> case do
        [] -> contract.summary
        gaps -> Enum.join(gaps, " ")
      end

    "#{issue_label(issue)} has a PR quality failure. #{details} " <>
      "Update the GitHub PR branch, title, and body so it matches the PR contract. " <>
      "Then re-emit `set_pr_url` or ask Cympho to recheck, and leave a `[delivery]` comment with what changed, validation, risks, current state, and next decision.\n\n" <>
      repair_packet
  end

  defp contract_nudge_prompt(issue, %{key: :memory_summary} = contract) do
    "#{issue_label(issue)} has weak issue memory. #{contract.summary} " <>
      "Leave one concise tagged comment that refreshes the owner-readable memory.\n\n" <>
      contract.prompt
  end

  defp contract_nudge_prompt(issue, contract) do
    fields = contract_missing_field_sentence(contract)
    status = contract |> Map.get(:status) |> contract_status_word()

    "#{issue_label(issue)} has a #{status} #{contract.label} contract. " <>
      "#{fields} Add `#{contract.prompt}` before moving the issue forward."
  end

  defp contract_nudge_summary(contract) do
    "Repair #{contract.label}: #{contract_missing_field_sentence(contract)}"
  end

  defp pr_quality_contracts(%Issue{monitor_state: %{"pr_quality" => pr_quality}} = issue)
       when is_map(pr_quality) do
    case pr_quality["status"] do
      "attention" ->
        gaps = List.wrap(pr_quality["gaps"])
        labels = gaps |> Enum.map(&(&1["label"] || &1[:label])) |> Enum.reject(&is_nil/1)

        details = pr_quality_gap_details(gaps)

        [
          %{
            key: :pr_quality,
            label: "PR quality gate",
            role: "Delivery owner",
            status: :attention,
            summary: pr_quality["summary"] || "PR quality gate needs fixes.",
            prompt:
              "#{details} Fix the GitHub PR branch/title/body, then re-emit `set_pr_url` or ask Cympho to recheck. Leave a `[delivery]` comment summarizing the PR fixes.\n\n#{PullRequestContract.repair_packet_markdown(issue, pr_quality)}",
            missing_fields: labels,
            pr_gaps: gaps
          }
        ]

      _ ->
        []
    end
  end

  defp pr_quality_contracts(_issue), do: []

  defp pr_quality_payload(%Issue{monitor_state: %{"pr_quality" => pr_quality}})
       when is_map(pr_quality),
       do: pr_quality

  defp pr_quality_payload(_issue), do: nil

  defp pr_quality_gap_details(gaps) do
    gaps
    |> Enum.map(&(&1["detail"] || &1[:detail]))
    |> Enum.reject(&(&1 in [nil, ""]))
    |> case do
      [] -> "PR quality gate needs fixes."
      details -> Enum.join(details, " ")
    end
  end

  defp contract_missing_field_sentence(%{missing_fields: fields})
       when is_list(fields) and fields != [] do
    "Missing fields: #{Enum.join(fields, ", ")}."
  end

  defp contract_missing_field_sentence(_contract),
    do: "Follow the required tagged comment template."

  defp contract_status_word(:missing), do: "missing"
  defp contract_status_word(:attention), do: "weak"
  defp contract_status_word(status), do: status |> to_string() |> String.downcase()

  defp issue_label(%{identifier: identifier, title: title}),
    do: "#{identifier || "Issue"} · #{title}"

  defp issue_label(%{issue_identifier: identifier, issue_title: title}) do
    "#{identifier || "Issue"} · #{title}"
  end

  defp button_label(:delivery), do: "Nudge delivery owner"
  defp button_label(:cto_review), do: "Nudge CTO review"
  defp button_label(:ceo_update), do: "Nudge CEO update"
  defp button_label(:child_work), do: "Nudge child owner"
  defp button_label(:contract_delivery), do: "Nudge delivery contract"
  defp button_label(:contract_review), do: "Nudge review contract"
  defp button_label(:contract_owner), do: "Nudge owner update"
  defp button_label(:memory_summary), do: "Request summary"
  defp button_label(:pr_quality), do: "Fix PR quality"
  defp button_label(_), do: "Queue nudge"

  defp summary(:delivery, blockers) do
    "Ask for one tagged delivery note covering #{labels_sentence(blockers)}."
  end

  defp summary(:cto_review, _blockers), do: "Route evidence to CTO for review."
  defp summary(:ceo_update, _blockers), do: "Ask CEO for an owner-facing status update."

  defp summary(:child_work, _blockers) do
    "Push the open child issue to completion or a blocked note."
  end

  defp summary(_type, blockers), do: prompts_sentence(blockers)

  defp labels_sentence(blockers) do
    blockers
    |> Enum.map(& &1.label)
    |> labels_sentence_from_strings()
  end

  defp labels_sentence_from_strings([]), do: "review evidence"
  defp labels_sentence_from_strings(labels), do: Enum.join(labels, ", ")

  defp prompts_sentence(blockers) do
    blockers
    |> Enum.map(& &1.prompt)
    |> Enum.join(" ")
  end

  defp agent_name(%Agent{name: name}) when is_binary(name), do: name
  defp agent_name(%Agent{id: id}), do: "Agent #{String.slice(id, 0, 8)}"
  defp agent_name(_), do: "No matching agent"

  defp agent_role(%Agent{role: role}, _type), do: to_string(role)
  defp agent_role(_agent, :cto_review), do: "cto"
  defp agent_role(_agent, :ceo_update), do: "ceo"
  defp agent_role(_agent, :contract_review), do: "cto"
  defp agent_role(_agent, :contract_owner), do: "ceo"
  defp agent_role(_agent, :memory_summary), do: "engineer"
  defp agent_role(_agent, _type), do: nil
end
