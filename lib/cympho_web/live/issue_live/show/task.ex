defmodule CymphoWeb.IssueLive.Show.Task do
  @moduledoc """
  The r3 Task page (build plan P2; mockup `v5/pages/task.html`): `view/2`, the
  page's reading of the task (also feeding the header block in
  `CymphoWeb.IssueLive.Show.Header`), then the Next step for the task's state,
  the thread, deliverables, runs and the details rail.

  Function components over what `CymphoWeb.IssueLive.Show` loads; every
  action is one of that LiveView's events. The Next step by state (v2 spec
  §3.4): a pending question, confirmation or task proposal; a review waiting
  on the owner; a blocked task that needs someone to retry it; a cancelled
  task; else all clear. Its copy is the effect library's (v2 spec §1.3).
  """
  use CymphoWeb, :html

  import CymphoWeb.Format, only: [money: 1]

  alias Cympho.Agents.Agent

  @problem_kinds [:agent_paused, :failed_run, :stuck_issue, :human_action]
  @failed ~w(failed timed_out)
  @finished ~w(completed succeeded)
  @runs_shown 6

  ## ── The page's view of the task ──────────────────────────────

  @doc """
  What the page shows, from the LiveView's assigns: `issue`, `runs`,
  `interactions`, `work_products`, `all_agents`, `comment_authors`,
  `task_item` (the task's `Cympho.OwnerAttention` item or nil), `task_cost`,
  `previous_assignee_id`, `retry_choice` and `current_user`.
  """
  def view(assigns, gate_actions \\ []) do
    issue = assigns.issue
    agents = Map.new(assigns.all_agents, &{&1.id, &1})
    pending = Enum.filter(assigns.interactions, &(&1.status == :pending))
    item = assigns.task_item
    live = Enum.find(assigns.runs, &(&1.status == "running"))
    signoff? = Enum.any?(gate_actions, &(Map.get(&1, :event) == "accept_owner_verification"))
    kind = next_kind(issue, item, pending, signoff?)
    names = people(issue, assigns)

    %{
      kind: kind,
      status: status_chip(issue, kind, live),
      person: person_chip(issue, agents, names, assigns.previous_assignee_id),
      priority: priority_chip(issue.priority),
      status_options: status_options(issue.status),
      priority_options: priority_options(),
      brief: brief(issue, names),
      now: now(issue, kind, live, pending, agents, assigns.task_item),
      assignee: Map.get(agents, issue.assignee_id),
      help: composer_help(issue, agents),
      names: names,
      agents: agents,
      pending: pending,
      retry: kind == :retry && retry(issue, agents, assigns),
      close_blockers: assigns[:task_close_blockers] || [],
      runs: runs_view(assigns.runs),
      thread: thread(issue, assigns.interactions, assigns.runs, pending, agents, names),
      deliverables: deliverables(issue, assigns.work_products, agents)
    }
  end

  # A pending question leads (S5: the task's own action), then a review the
  # owner decides (an agent's delivery, or the CEO's update handed back for the
  # owner's sign-off), then a blocked task's retry. Cancelled and all clear close it.
  defp next_kind(%{status: :cancelled}, _item, _pending, _signoff?), do: :cancelled
  defp next_kind(%{status: :done}, _item, _pending, _signoff?), do: :clear
  defp next_kind(_issue, _item, [_ | _], _signoff?), do: :question
  defp next_kind(_issue, %{kind: :review_queue}, _pending, _signoff?), do: :review
  defp next_kind(_issue, _item, _pending, true), do: :signoff

  defp next_kind(%{status: :blocked}, %{kind: kind}, _pending, _signoff?)
       when kind in @problem_kinds,
       do: :retry

  defp next_kind(_issue, _item, _pending, _signoff?), do: :clear

  ## ── The Next step ────────────────────────────────────────────

  attr :issue, :map, required: true
  attr :v, :map, required: true
  attr :item, :map, default: nil
  attr :review_changes, :map, default: nil
  attr :reply_id, :string, required: true

  def task_next(assigns) do
    ~H"""
    <%= case @v.kind do %>
      <% :question -> %>
        <.question_step issue={@issue} v={@v} interaction={hd(@v.pending)} item={@item} />
      <% :review -> %>
        <.review_step issue={@issue} v={@v} item={@item} review_changes={@review_changes} />
      <% :signoff -> %>
        <.signoff_step issue={@issue} v={@v} />
      <% :retry -> %>
        <.retry_step issue={@issue} v={@v} />
      <% :cancelled -> %>
        <.cancelled_step issue={@issue} v={@v} />
      <% :clear -> %>
        <.clear_step issue={@issue} v={@v} reply_id={@reply_id} />
    <% end %>
    """
  end

  attr :issue, :map, required: true
  attr :v, :map, required: true
  attr :interaction, :map, required: true
  attr :item, :map, default: nil

  defp question_step(assigns) do
    interaction = assigns.interaction
    agent = Map.get(assigns.v.agents, interaction.created_by_agent_id)
    name = (agent && agent.name) || "The agent"
    id = assigns.issue.identifier
    questions = questions(interaction, assigns.item)

    assigns =
      assign(assigns,
        name: name,
        agent: agent,
        questions: questions,
        title: question_title(interaction.kind, name, length(questions)),
        payload: interaction.payload || %{},
        note:
          if(interaction.kind == :ask_user_questions,
            do:
              "After you send: #{name} gets your #{if length(questions) > 1, do: "answers", else: "answer"} as a comment and is asked to carry on with #{id}.",
            else:
              "After you decide: #{name} gets your decision and is asked to carry on with #{id}."
          )
      )

    ~H"""
    <.next_step>
      <:problem>
        <.problem_card title={@title}>
          <:eyebrow>
            Next step<span aria-hidden="true"> · </span>Question<span aria-hidden="true"> · </span>
            <span class="mono">
              {clock(@interaction.inserted_at)}
            </span>
          </:eyebrow>
          <blockquote :if={@interaction.kind == :ask_user_questions} class="quote" id="ns-q">
            <.quote_mark />
            <p :if={length(@questions) == 1}>{hd(@questions).question}</p>
            <ol :if={length(@questions) > 1} class="qs">
              <li :for={q <- @questions}>
                {q.question}
                <%!-- With several questions the answer is one text; the offered answers stay readable. --%>
                <ol :if={q.options != []} class="qs-o">
                  <li :for={{option, n} <- Enum.with_index(q.options, 1)}>{n}. {option}</li>
                </ol>
              </li>
            </ol>
          </blockquote>
          <blockquote :if={@interaction.kind == :request_confirmation} class="quote" id="ns-q">
            <.quote_mark />
            <p>{@payload["message"] || "Please confirm."}</p>
          </blockquote>
          <p :if={@interaction.kind == :request_confirmation && @payload["details"]} class="obj">
            {@payload["details"]}
          </p>
          <div :if={@interaction.kind == :suggest_tasks} id="ns-q">
            <p class="obj">{@payload["message"] || "Proposed tasks:"}</p>
            <ol class="qs">
              <li :for={task <- List.wrap(@payload["tasks"])}>{task_title(task)}</li>
            </ol>
          </div>
          <:foot>
            <span class="who">
              <span class="tile-ag sm" aria-hidden="true">{initials(@name)}</span><span><b>{@name}</b><span :if={
                @agent
              }><span aria-hidden="true"> · </span>{Agent.role_label(@agent.role)}</span></span>
            </span>
            <a class="ul" href="#thread">See the thread</a>
          </:foot>
        </.problem_card>
      </:problem>
      <:resolution>
        <.ink_card
          :if={@interaction.kind == :ask_user_questions}
          form={@title}
          id="ns-answer"
          phx-submit="respond_questions"
        >
          <input type="hidden" name="_id" value={@interaction.id} />
          <.option_rows
            :if={match?([%{options: [_ | _]}], @questions)}
            name="response"
            legend="Your answer"
            items={Enum.map(hd(@questions).options, &%{value: &1, label: &1})}
            describedby="ns-q"
          />
          <fieldset
            :if={!match?([%{options: [_ | _]}], @questions)}
            class="opts"
            aria-describedby="ns-q"
          >
            <legend>{if length(@questions) > 1, do: "Your answers", else: "Your answer"}</legend>
            <div class="own-box open">
              <label class="sr" for="ns-own">Your answer</label>
              <textarea id="ns-own" name="own_response" rows="3"></textarea>
            </div>
          </fieldset>
          <.ink_note>{@note}</.ink_note>
          <.ink_foot verb="send">
            <:primary>
              <.primary_pill type="submit">Send answer</.primary_pill>
            </:primary>
          </.ink_foot>
        </.ink_card>
        <.ink_card :if={@interaction.kind != :ask_user_questions} heading="Your decision">
          <.ink_note>{@note}</.ink_note>
          <.ink_foot verb="decide">
            <:secondary>
              <.ghost_pill
                phx-click="resolve_interaction"
                phx-value-id={@interaction.id}
                phx-value-status="rejected"
              >
                {if @interaction.kind == :suggest_tasks, do: "Reject", else: "Decline"}
              </.ghost_pill>
            </:secondary>
            <:primary>
              <.primary_pill
                phx-click="resolve_interaction"
                phx-value-id={@interaction.id}
                phx-value-status="accepted"
              >
                {if @interaction.kind == :suggest_tasks, do: "Accept tasks", else: "Confirm"}
              </.primary_pill>
            </:primary>
          </.ink_foot>
        </.ink_card>
      </:resolution>
    </.next_step>
    """
  end

  attr :issue, :map, required: true
  attr :v, :map, required: true
  attr :item, :map, required: true
  attr :review_changes, :map, default: nil

  defp review_step(assigns) do
    issue = assigns.issue
    id = issue.identifier
    person = (assigns.v.assignee && assigns.v.assignee.name) || "the team"
    report = latest_agent_note(issue, assigns.v.agents)

    assigns =
      assign(assigns,
        id: id,
        person: person,
        report: report,
        accept: "After you accept: #{id} is marked Done.",
        send_back:
          "After you send it: #{id} goes back to To do with your note, for the next free #{return_role(issue.assigned_role)}."
      )

    ~H"""
    <.next_step>
      <:problem>
        <.problem_card title={"Review #{@person}'s work"}>
          <:eyebrow>
            Next step<span aria-hidden="true"> · </span>Review<span aria-hidden="true"> · </span>
            <span class="mono">
              {clock(@item.inserted_at)}
            </span>
          </:eyebrow>
          <p :if={@report} class="obj"><b>{@report.by} reports:</b> {@report.text}</p>
          <p :if={!@report} class="obj"><b>{@issue.title}</b> is ready for your review.</p>
          <p :if={@v.close_blockers != []} class="obj gate">
            <b>Closing needs:</b> {Enum.join(@v.close_blockers, ", ")}.
          </p>
          <:foot>
            <span>Evidence first</span>
            <a :if={@v.deliverables.items != []} class="ul" href="#deliverables">
              See the deliverables
            </a>
            <a :if={@v.deliverables.items == []} class="ul" href="#thread">See the thread</a>
          </:foot>
        </.problem_card>
      </:problem>
      <:resolution>
        <.ink_card :if={!@review_changes} heading={"Decide on #{@id}"}>
          <.consequences rows={[{:done, @accept}, {:idle, @send_back}]} />
          <.ink_note :if={@v.close_blockers != []}>
            Accept & close unlocks once what closing needs is in. You can still send it back.
          </.ink_note>
          <.ink_foot verb="accept">
            <:secondary>
              <.ghost_pill phx-click="request_changes" phx-value-id={@issue.id}>
                Request changes
              </.ghost_pill>
            </:secondary>
            <:primary>
              <.primary_pill
                phx-click="approve_review"
                phx-value-id={@issue.id}
                disabled={@v.close_blockers != []}
              >
                Accept & close
              </.primary_pill>
            </:primary>
          </.ink_foot>
        </.ink_card>
        <.ink_card
          :if={@review_changes}
          form={"Request changes on #{@id}"}
          id="ns-changes"
          phx-submit="submit_review_changes"
        >
          <label class="ink-h" for="ns-reason">What should change?</label>
          <div class="own-box open">
            <textarea
              id="ns-reason"
              name="review[reason]"
              rows="3"
              aria-describedby={@review_changes.error && "ns-reason-err"}
            >{@review_changes.reason}</textarea>
            <p :if={@review_changes.error} id="ns-reason-err" class="ink-err" role="alert">
              {@review_changes.error}
            </p>
          </div>
          <.ink_note>{@send_back}</.ink_note>
          <.ink_foot verb="send">
            <:secondary>
              <.ghost_pill phx-click="cancel_review_changes">Cancel</.ghost_pill>
            </:secondary>
            <:primary>
              <.primary_pill type="submit">Send it</.primary_pill>
            </:primary>
          </.ink_foot>
        </.ink_card>
      </:resolution>
    </.next_step>
    """
  end

  attr :issue, :map, required: true
  attr :v, :map, required: true

  # The CEO handed the task back for the owner's sign-off (Home draws the same
  # decision, CymphoWeb.NextStep): accept and close, or ask for a revision.
  defp signoff_step(assigns) do
    id = assigns.issue.identifier
    ceo = assigns.v.assignee && assigns.v.assignee.name
    report = latest_agent_note(assigns.issue, assigns.v.agents)

    assigns =
      assign(assigns,
        id: id,
        ceo: ceo,
        report: report,
        effects:
          [{:done, "After you accept: #{id} is marked Done."}] ++
            if(ceo,
              do: [{:idle, "After you ask for a revision: #{id} goes back to To do for #{ceo}."}],
              else: []
            )
      )

    ~H"""
    <.next_step>
      <:problem>
        <.problem_card title={if @ceo, do: "Review #{@ceo}'s update", else: "Review the owner update"}>
          <:eyebrow>Next step<span aria-hidden="true"> · </span>Review</:eyebrow>
          <p :if={@report} class="obj"><b>{@report.by} reports:</b> {@report.text}</p>
          <:foot>
            <span>Evidence first</span>
            <a class="ul" href="#thread">See the thread</a>
          </:foot>
        </.problem_card>
      </:problem>
      <:resolution>
        <.ink_card heading={"Decide on #{@id}"}>
          <.consequences rows={@effects} />
          <.ink_foot verb="accept">
            <:secondary>
              <.ghost_pill
                phx-click="request_owner_revision"
                data-confirm="Request a CEO revision, reopen this issue to To Do, and queue focused dispatch?"
              >
                Request revision
              </.ghost_pill>
            </:secondary>
            <:primary>
              <.primary_pill
                phx-click="accept_owner_verification"
                data-confirm="Accept this CEO owner update and close the issue?"
              >
                Accept and close
              </.primary_pill>
            </:primary>
          </.ink_foot>
        </.ink_card>
      </:resolution>
    </.next_step>
    """
  end

  attr :issue, :map, required: true
  attr :v, :map, required: true

  defp retry_step(assigns) do
    ~H"""
    <.next_step>
      <:problem>
        <.problem_card title={"Decide who retries #{@issue.identifier}"}>
          <:eyebrow>
            Next step<span aria-hidden="true"> · </span>{@v.status.word}<span :if={@v.retry.since}><span aria-hidden="true"> · </span>since
              <span class="mono">{@v.retry.since}</span></span>
          </:eyebrow>
          <p class="obj"><b :if={@v.retry.lead}>{@v.retry.lead}</b> {@v.retry.rest}</p>
          <:foot>
            <span>Runs on this task</span>
            <a class="ul" href="#runs">See the runs</a>
          </:foot>
        </.problem_card>
      </:problem>
      <:resolution>
        <.ink_card
          :if={@v.retry.options != []}
          form={"Assign #{@issue.identifier} and retry"}
          id="ns-retry"
          phx-submit="assign_and_retry"
          phx-change="pick_retry_agent"
        >
          <.option_rows
            name="agent_id"
            legend="Who should retry it?"
            items={@v.retry.options}
            checked={@v.retry.choice && @v.retry.choice.id}
            own={false}
          />
          <.ink_note :if={@v.retry.choice}>
            After you assign: {@issue.identifier} goes to {@v.retry.choice.name} and starts when they're free; this band then says Queued or Started.
          </.ink_note>
          <.ink_foot verb="assign">
            <:primary>
              <.primary_pill type="submit" disabled={!@v.retry.choice}>
                Assign and retry
              </.primary_pill>
            </:primary>
          </.ink_foot>
        </.ink_card>
        <.ink_card :if={@v.retry.options == []} heading="Nobody can take it">
          <.ink_note>No agent with this task's role is available. Hire one in Team.</.ink_note>
          <.ink_foot verb="open">
            <:primary>
              <.primary_pill navigate="/agents">Open Team</.primary_pill>
            </:primary>
          </.ink_foot>
        </.ink_card>
      </:resolution>
    </.next_step>
    """
  end

  attr :issue, :map, required: true
  attr :v, :map, required: true

  defp cancelled_step(assigns) do
    assigns = assign(assigns, :last_note, last_note_before(assigns.issue, assigns.v))

    ~H"""
    <.next_step>
      <:problem>
        <.problem_card title={"Cancelled on #{day(@issue.cancelled_at || @issue.updated_at)}"}>
          <:eyebrow>Cancelled</:eyebrow>
          <p :if={@last_note} class="obj">
            <b>“{@last_note.text}”</b> — {@last_note.by}
          </p>
        </.problem_card>
      </:problem>
      <:resolution>
        <.ink_card heading="After you reopen">
          <.consequences rows={[{:idle, "#{@issue.identifier} goes back to To do."}]} />
          <.ink_foot verb="reopen">
            <:primary>
              <.primary_pill phx-click="update_status" phx-value-status="todo">Reopen</.primary_pill>
            </:primary>
          </.ink_foot>
        </.ink_card>
      </:resolution>
    </.next_step>
    """
  end

  attr :issue, :map, required: true
  attr :v, :map, required: true
  attr :reply_id, :string, required: true

  defp clear_step(assigns) do
    assigns =
      assign(assigns, word: clear_word(assigns.issue), line: clear_line(assigns.issue, assigns.v))

    ~H"""
    <.next_step>
      <:problem>
        <.problem_card title="Nothing needed from you">
          <:eyebrow>
            All clear<span :if={@word}><span aria-hidden="true"> · </span>{@word}</span>
          </:eyebrow>
          <p :if={@line} class="obj">{@line}</p>
        </.problem_card>
      </:problem>
      <:resolution>
        <.ink_card heading="After you comment">
          <.ink_note>{@v.help}</.ink_note>
          <.ink_foot verb="comment">
            <:primary>
              <.primary_pill phx-click={JS.focus(to: "##{@reply_id}")}>Add a comment</.primary_pill>
            </:primary>
          </.ink_foot>
        </.ink_card>
      </:resolution>
    </.next_step>
    """
  end

  defp quote_mark(assigns) do
    ~H"""
    <svg class="qm" viewBox="0 0 32 24" aria-hidden="true">
      <path d="M1 24V14.5C1 6.9 5.2 1.7 12.6 0l1.7 3.3C10.2 5 8.2 8 7.9 12H13.5v12zM18 24V14.5C18 6.9 22.2 1.7 29.6 0l1.7 3.3C27.2 5 25.2 8 24.9 12h5.6v12z" />
    </svg>
    """
  end

  ## ── Thread, deliverables, runs, details ──────────────────────

  attr :issue, :map, required: true
  attr :v, :map, required: true
  attr :reply_id, :string, required: true

  def task_thread(assigns) do
    ~H"""
    <section class="card" id="thread" aria-labelledby="th-t">
      <div class="card-h">
        <h2 class="h2" id="th-t">Thread</h2>
      </div>
      <article :if={@v.thread.latest} class="msg">
        <span class="tile-ag" aria-hidden="true">{initials(@v.thread.latest.by)}</span>
        <div>
          <p class="msg-h">
            <b>{@v.thread.latest.by}</b><span class="mono">{stamp(@v.thread.latest.at)}</span><span class="tag">Latest update</span>
          </p>
          <div class="msg-b">{@v.thread.latest.body}</div>
        </div>
      </article>
      <p :if={!@v.thread.latest} class="quiet-line">No update from an agent yet.</p>
      <details :if={@v.thread.earlier != []} class="earlier">
        <summary>
          <span>{@v.thread.summary}</span> <.r3_icon name="i-chev-down" />
        </summary>
        <div class="thread-old">
          <%= for entry <- @v.thread.earlier do %>
            <p :if={entry.type == :run} class="runline">{entry.text}</p>
            <article :if={entry.type == :msg} class="msg">
              <span class="tile-ag" aria-hidden="true">{initials(entry.by)}</span>
              <div>
                <p class="msg-h"><b>{entry.by}</b><span class="mono">{stamp(entry.at)}</span></p>
                <div class="msg-b">{entry.body}</div>
              </div>
            </article>
          <% end %>
        </div>
      </details>
      <.composer
        id={@reply_id}
        name="comment[body]"
        label={if @v.assignee, do: "Reply to #{@v.assignee.name}", else: "Add a comment"}
        help={@v.help}
        button={if @v.assignee, do: "Send reply", else: "Send"}
        phx-submit="add_comment"
      />
    </section>
    """
  end

  attr :v, :map, required: true
  attr :issue, :map, required: true
  attr :gate_actions, :list, default: []
  attr :open_form, :boolean, default: false, doc: "the attach-proof or set-PR form is open"
  slot :inner_block

  def task_deliverables(assigns) do
    gates = if assigns.issue.status in [:done, :cancelled], do: [], else: assigns.gate_actions
    assigns = assign(assigns, :gates, proof_gates(gates))

    ~H"""
    <section
      :if={@v.deliverables.items != [] or @gates != [] or @open_form}
      class="card"
      id="deliverables"
      aria-labelledby="dl-t"
      data-testid="issue-simple-proof"
    >
      <div class="card-h">
        <h2 class="h2" id="dl-t">Deliverables</h2>
        <span :if={@gates != []} class="ui-simple-only dl-gates">
          <button
            :for={gate <- @gates}
            type="button"
            class="pl"
            phx-click="resolve_review_gate"
            phx-value-action={gate.action}
            data-testid={"issue-simple-gate-#{gate.action}"}
          >
            {gate.label}
          </button>
        </span>
      </div>
      <div :if={@v.deliverables.items != []} class="objs">
        <%= for d <- @v.deliverables.items do %>
          <.object_tile
            :if={d.href}
            kind={d.kind}
            title={d.title}
            href={d.href}
            go={d.go}
            external={d.external}
          >
            <:sub_line><.deliverable_sub d={d} /></:sub_line>
          </.object_tile>
          <details :if={!d.href} class="objt objt-d">
            <summary>
              {Phoenix.HTML.raw(d.file)}
              <span class="objt-m">
                <span class="objt-t">{d.title}</span><span class="objt-s"><.deliverable_sub d={d} /></span>
              </span>
              <span class="go" aria-hidden="true">Show</span>
            </summary>
            <p class="objt-body">{d.body || "Nothing was attached to read here."}</p>
          </details>
        <% end %>
      </div>
      {render_slot(@inner_block)}
    </section>
    """
  end

  attr :d, :map, required: true

  # "Document · Ravi · Mon 15:24", the time in mono as in the mockup.
  defp deliverable_sub(assigns) do
    ~H"""
    {@d.sub}<span :if={@d.at}><span aria-hidden="true"> · </span>{stamp_day(@d.at)} <span class="mono">{clock(@d.at)}</span></span>
    """
  end

  attr :v, :map, required: true

  def task_runs(assigns) do
    ~H"""
    <section :if={@v.runs.items != []} class="card" id="runs" aria-labelledby="ru-t">
      <div class="card-h">
        <h2 class="h2" id="ru-t">Runs on this task</h2>
        <span :if={@v.runs.more > 0} class="meta">
          Last {length(@v.runs.items)} of {length(@v.runs.items) + @v.runs.more}
        </span>
      </div>
      <ol class="steps">
        <li :for={run <- @v.runs.items} class={["step", run.tone]}>
          <span class="chk"><.r3_icon name={run.icon} class="ico s14" /></span>
          <span class="step-t"><span class="mono">{stamp(run.at)}</span>{run.text}</span>
          <span class="step-c">{run.cost}</span>
        </li>
      </ol>
    </section>
    """
  end

  attr :issue, :map, required: true
  attr :v, :map, required: true
  attr :cost, :any, required: true
  attr :mobile, :boolean, default: false

  def task_details(assigns) do
    ~H"""
    <details :if={@mobile} class="card det-m">
      <summary><span class="h2">Details</span> <.r3_icon name="i-chev-down" /></summary>
      <.details_list issue={@issue} v={@v} cost={@cost} />
    </details>
    <aside :if={!@mobile} class="aside task-aside card" aria-labelledby="dt-t">
      <div class="card-h band">
        <h2 class="h2" id="dt-t">Details</h2>
      </div>
      <.details_list issue={@issue} v={@v} cost={@cost} />
    </aside>
    """
  end

  attr :issue, :map, required: true
  attr :v, :map, required: true
  attr :cost, :any, required: true

  defp details_list(assigns) do
    ~H"""
    <.kv_list>
      <:item :if={project_name(@issue)} term="Project">{project_name(@issue)}</:item>
      <:item :if={goal_title(@issue)} term="Goal">{goal_title(@issue)}</:item>
      <:item term="Created">
        {day(@issue.inserted_at)}
        <span class="mono">{clock(@issue.inserted_at)}</span><span :if={@v.names.creator}> by {@v.names.creator}</span>
      </:item>
      <:item term="Task cost">
        <span class="mono">{money(@cost)}</span> {if @issue.status in [:done, :cancelled],
          do: "in total",
          else: "so far"}
      </:item>
      <:item term="Advanced">
        <.link class="ul" navigate={"/workspace/#{@issue.id}"}>Work files</.link><span aria-hidden="true"> · </span><.link
          class="ul"
          navigate="/tool-call-traces"
        >Step log</.link><span class="adv">Adv</span>
      </:item>
    </.kv_list>
    """
  end

  ## ── Chips ────────────────────────────────────────────────────

  # Spec §1.5: one word per state, with its shape. A question or a review the
  # owner decides is "Waiting on you", which wins over the stored Blocked.
  defp status_chip(_issue, kind, _live) when kind in [:question, :review, :signoff],
    do: %{kind: :waiting, word: "Waiting on you"}

  defp status_chip(%{status: :in_progress}, _kind, _live), do: %{kind: :working, word: "Working"}

  defp status_chip(%{status: :in_review}, _kind, live),
    do: %{kind: if(live, do: :working, else: :idle), word: "In review"}

  defp status_chip(%{status: status}, _kind, _live), do: Map.fetch!(status_words(), status)

  defp status_words do
    %{
      backlog: %{kind: :idle, word: "Later"},
      todo: %{kind: :idle, word: "To do"},
      blocked: %{kind: :stopped, word: "Blocked"},
      done: %{kind: :done, word: "Done"},
      cancelled: %{kind: :idle, word: "Cancelled"}
    }
  end

  # The status choices in the owner's words; the current status first.
  defp status_options(current) do
    words = %{
      backlog: "Later",
      todo: "To do",
      in_progress: "Working",
      in_review: "In review",
      blocked: "Blocked",
      done: "Done",
      cancelled: "Cancelled"
    }

    [current | Enum.reject(Cympho.Issues.Issue.status_options(), &(&1 == current))]
    |> Enum.map(&%{id: to_string(&1), label: Map.fetch!(words, &1)})
  end

  defp priority_options do
    Enum.map(Cympho.Issues.Issue.priority_options(), fn p ->
      %{id: to_string(p), label: p |> to_string() |> String.capitalize()}
    end)
  end

  # "High" only when it applies (B8): high and critical.
  defp priority_chip(:high), do: %{word: "High", bars: [true, true, true, false]}
  defp priority_chip(:critical), do: %{word: "Critical", bars: [true, true, true, true]}
  defp priority_chip(_priority), do: nil

  defp person_chip(issue, agents, names, previous_id) do
    cond do
      agent = Map.get(agents, issue.assignee_id) ->
        %{initials: initials(agent.name), word: agent.name}

      names.assignee_user ->
        %{initials: initials(names.assignee_user), word: names.assignee_user}

      previous = Map.get(agents, previous_id) ->
        %{initials: nil, word: "Unassigned · was #{previous.name}"}

      true ->
        %{initials: nil, word: "Unassigned"}
    end
  end

  defp brief(%{description: description} = issue, names)
       when is_binary(description) and description != "" do
    by = if names.creator, do: "#{names.creator}'s brief", else: "The brief"

    %{by: by, day: day(issue.inserted_at), time: clock(issue.inserted_at)}
  end

  defp brief(_issue, _names), do: nil

  # Only while it says something: a live run, or the agent waiting on the owner.
  defp now(issue, _kind, %{} = live, _pending, agents, _item) do
    case Map.get(agents, live.agent_id) do
      nil ->
        nil

      agent ->
        reviewing? = issue.status == :in_review and live.agent_id != issue.assignee_id
        owner = Map.get(agents, issue.assignee_id)

        minutes =
          live.started_at && max(div(DateTime.diff(DateTime.utc_now(), live.started_at), 60), 0)

        doing =
          if reviewing? and owner, do: "is reviewing #{owner.name}'s work", else: "is working"

        %{
          state: :working,
          agent: agent,
          text: if(minutes, do: "#{doing} · #{minutes} min", else: doing),
          sub: "Cost shown when the run finishes"
        }
    end
  end

  defp now(issue, kind, nil, pending, agents, item) when kind in [:question, :review, :signoff] do
    {agent_id, waiting} =
      case {kind, pending} do
        {:question, [%{created_by_agent_id: id, kind: :ask_user_questions} | _]} ->
          {id, "is waiting for your answer"}

        {:question, [%{created_by_agent_id: id} | _]} ->
          {id, "is waiting for your decision"}

        {_review_or_signoff, _} ->
          {issue.assignee_id || (item && item.agent_id), "is waiting for your review"}
      end

    case Map.get(agents, agent_id) do
      nil ->
        nil

      agent ->
        %{
          state: :waiting,
          agent: agent,
          text: waiting,
          sub: "No run is live on #{issue.identifier}"
        }
    end
  end

  defp now(_issue, _kind, _live, _pending, _agents, _item), do: nil

  ## ── Retry ────────────────────────────────────────────────────

  # Who may retry: agents with the task's role (else the previous assignee's),
  # and the people they report to; paused agents are listed but disabled.
  # Without a known role, every active agent. At most four rows.
  defp retry(issue, agents, assigns) do
    previous = Map.get(agents, assigns.previous_assignee_id)
    current = Map.get(agents, issue.assignee_id)
    role = issue.assigned_role || role_of(previous) || role_of(current)

    active =
      agents
      |> Map.values()
      |> Enum.reject(&(&1.status in [:terminated, :pending_approval]))

    matched = if role, do: Enum.filter(active, &(to_string(&1.role) == role)), else: active
    managers = Enum.filter(active, &(&1.id in Enum.map(matched, fn a -> a.parent_id end)))

    candidates =
      (matched ++ managers)
      |> Enum.uniq_by(& &1.id)
      |> Enum.sort_by(&{&1.status == :paused, &1 not in matched, String.downcase(&1.name)})
      |> Enum.take(4)

    enabled = Enum.reject(candidates, &(&1.status == :paused))

    choice =
      Enum.find(enabled, &(&1.id == assigns.retry_choice)) ||
        Enum.find(enabled, &(&1.id == issue.assignee_id)) ||
        Enum.find(enabled, &(&1 in matched and &1.status in [:idle, :sleeping])) ||
        List.first(enabled)

    streak = assigns.runs |> Enum.take_while(&(&1.status in @failed)) |> length()
    last_failed = Enum.find(assigns.runs, &(&1.status in @failed))

    %{
      options:
        Enum.map(candidates, fn agent ->
          %{
            value: agent.id,
            label: agent.name,
            sub: "#{Agent.role_label(agent.role)} · #{agent_word(agent.status)}",
            disabled: agent.status == :paused
          }
        end),
      choice: choice,
      since: last_failed && clock(last_failed.completed_at || last_failed.inserted_at),
      lead:
        cond do
          streak == 1 -> "1 run failed;"
          streak > 1 -> "#{streak} runs failed;"
          true -> nil
        end,
      rest:
        cond do
          current -> "#{current.name} has it now."
          previous -> "nobody is assigned now (was #{previous.name})."
          true -> "nobody is assigned now."
        end
    }
  end

  defp role_of(%{role: role}) when not is_nil(role), do: to_string(role)
  defp role_of(_agent), do: nil

  # Spec §1.5 agent words.
  defp agent_word(status) when status in [:running, :active], do: "Working"
  defp agent_word(:error), do: "Stopped"
  defp agent_word(:paused), do: "Paused"
  defp agent_word(:offline), do: "Offline"
  defp agent_word(_idle_or_sleeping), do: "Idle"

  ## ── Thread ───────────────────────────────────────────────────

  # The latest update is the newest agent comment; everything else is the
  # earlier conversation, oldest first, with each finished run folded in as a
  # line where it ended. The open question shows only as a one-line pointer.
  defp thread(issue, interactions, runs, pending, agents, names) do
    comments = Enum.sort_by(comments(issue), & &1.inserted_at, DateTime)

    latest =
      comments
      |> Enum.filter(&(&1.author_type == "agent"))
      |> List.last()

    messages =
      comments
      |> Enum.reject(&(latest && &1.id == latest.id))
      |> Enum.map(fn c ->
        %{type: :msg, at: c.inserted_at, by: author(c, agents, names), body: render_body(c.body)}
      end)

    pointers =
      Enum.map(interactions, fn i ->
        %{
          type: :msg,
          at: i.inserted_at,
          by: agent_name(agents, i.created_by_agent_id),
          body: interaction_line(i, pending)
        }
      end)

    run_lines =
      runs
      |> Enum.reject(&(&1.status in ["running", "pending", "queued"]))
      |> Enum.map(fn r ->
        %{type: :run, at: r.completed_at || r.inserted_at, text: run_line(r)}
      end)

    earlier =
      Enum.sort_by(
        messages ++ pointers ++ run_lines,
        &{DateTime.to_unix(to_dt(&1.at)), &1.type == :run}
      )

    msg_count = Enum.count(earlier, &(&1.type == :msg))
    run_count = length(run_lines)
    finished? = Enum.all?(runs, &(&1.status in @finished or &1.status == "running"))

    summary =
      ["Earlier in the thread"] ++
        if(msg_count > 0, do: [count(msg_count, "message")], else: []) ++
        if(run_count > 0,
          do: [count(run_count, if(finished?, do: "finished run", else: "run"))],
          else: []
        )

    %{
      latest:
        latest &&
          %{
            at: latest.inserted_at,
            by: author(latest, agents, names),
            body: render_body(latest.body)
          },
      earlier: earlier,
      summary: Enum.join(summary, " · ")
    }
  end

  defp interaction_line(%{status: :pending} = i, pending) do
    open? = match?([%{id: id} | _] when id == i.id, pending)

    case {i.kind, open?} do
      {:ask_user_questions, true} -> "Asked you a question. It is open in the Next step above."
      {:request_confirmation, true} -> "Asked you to confirm. It is open in the Next step above."
      {:suggest_tasks, true} -> "Proposed tasks. They are open in the Next step above."
      {_kind, false} -> "Asked you something that is still open."
    end
  end

  defp interaction_line(%{kind: :ask_user_questions} = i, _pending) do
    case List.wrap((i.payload || %{})["questions"]) do
      [%{"question" => q} | _] -> "Asked you: “#{q}”"
      _ -> "Asked you a question."
    end
  end

  defp interaction_line(%{kind: kind, status: status}, _pending) do
    what = if kind == :suggest_tasks, do: "Proposed tasks", else: "Asked you to confirm"
    "#{what} · #{status |> to_string() |> String.capitalize()}"
  end

  defp run_line(run) do
    minutes = run_minutes(run)
    cost = positive(run.cost_usd)

    [run_word(run.status) |> then(&"Run #{&1}"), minutes && "#{minutes} min", cost && money(cost)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp render_body(body) do
    body
    |> to_string()
    |> String.replace(~r/```cympho[-_ ]?actions.*?```/s, "")
    |> String.trim()
    |> CymphoWeb.Markdown.to_html()
  end

  ## ── Runs and deliverables ────────────────────────────────────

  defp runs_view(runs) do
    shown = Enum.take(runs, @runs_shown)

    items =
      shown
      |> Enum.reverse()
      |> Enum.map(fn run ->
        minutes = run_minutes(run)
        live? = run.status == "running"

        %{
          at:
            if(live?, do: run.started_at, else: run.completed_at) || run.started_at ||
              run.inserted_at,
          text:
            "Run #{run_word(run.status)}" <>
              if(minutes && !live?, do: " · #{minutes} min", else: ""),
          cost: if(live?, do: "", else: money(run.cost_usd || Decimal.new(0))),
          icon:
            cond do
              run.status in @failed -> "i-stop"
              live? -> "i-term"
              true -> "i-check"
            end,
          tone: if(run.status in @failed, do: "failed", else: nil)
        }
      end)

    %{items: items, more: length(runs) - length(shown)}
  end

  defp deliverables(issue, work_products, agents) do
    items =
      work_products
      |> Enum.sort_by(& &1.inserted_at, DateTime)
      |> Enum.map(fn wp ->
        url = present(wp.url)
        github? = is_binary(url) and String.contains?(url, "github.com")

        %{
          kind: if(wp.kind == "code_change", do: :code, else: :doc),
          title: wp.title,
          href: url,
          external: is_binary(url),
          go: if(github?, do: "Open on GitHub", else: "Open"),
          sub:
            [kind_word(wp.kind, github?), agent_name(agents, wp.created_by_agent_id)]
            |> Enum.reject(&(&1 in [nil, "Someone"]))
            |> Enum.join(" · "),
          at: wp.inserted_at,
          body: present(wp.description) || present((wp.payload || %{})["text"]),
          file: if(wp.kind == "code_change", do: code_file(), else: doc_file())
        }
      end)

    pr_url = Cympho.Issues.Issue.pr_url(issue, loaded(issue.project))

    pr =
      if is_binary(pr_url) and pr_url != "" and not Enum.any?(items, &(&1.href == pr_url)) do
        [
          %{
            kind: :code,
            title: pr_title(issue, pr_url),
            href: pr_url,
            external: true,
            go: if(String.contains?(pr_url, "github.com"), do: "Open on GitHub", else: "Open"),
            sub: "Pull request",
            at: nil,
            body: nil,
            file: code_file()
          }
        ]
      else
        []
      end

    %{items: items ++ pr}
  end

  defp pr_title(%{github_pr_number: n}, _url) when is_integer(n), do: "PR ##{n}"

  defp pr_title(_issue, url) do
    case Regex.run(~r{/pull/(\d+)}, url) do
      [_, n] -> "PR ##{n}"
      _ -> "Pull request"
    end
  end

  defp kind_word("code_change", true), do: "Pull request"
  defp kind_word("code_change", false), do: "Code change"
  defp kind_word("document", _), do: "Document"
  defp kind_word("url", _), do: "Link"
  defp kind_word("artifact", _), do: "File"
  defp kind_word(_kind, _), do: "Other"

  # Only the two simple gates (attach proof, set the PR) stay on the page; the
  # rest are Advanced review-gate tools.
  defp proof_gates(actions) do
    actions
    |> List.wrap()
    |> Enum.filter(fn action ->
      action.type == :event and action.action in ["work_product", "code_reference"] and
        Map.get(action, :enabled?, true)
    end)
    |> Enum.uniq_by(& &1.action)
    |> Enum.map(fn
      %{action: "work_product"} = a -> Map.put(a, :label, "Attach proof")
      %{action: "code_reference"} = a -> Map.put(a, :label, "Set PR")
    end)
  end

  ## ── Words and helpers ────────────────────────────────────────

  # Comments wake the assignee only on Working and In review tasks (wakes.ex).
  defp composer_help(issue, agents) do
    case Map.get(agents, issue.assignee_id) do
      nil ->
        "Nobody is assigned; assign someone to get a reply."

      agent ->
        cond do
          issue.status in [:in_progress, :in_review] ->
            "Sending asks #{agent.name} to read it now."

          issue.status in [:done, :cancelled] ->
            "Saved to the thread; nobody works on this task now."

          true ->
            "#{agent.name} sees this the next time they work on this task."
        end
    end
  end

  defp clear_word(%{status: :done}), do: "Done"
  defp clear_word(%{status: :todo, assignee_id: id}) when is_binary(id), do: "Queued"
  defp clear_word(%{status: :in_progress}), do: "Started"
  defp clear_word(_issue), do: nil

  defp clear_line(%{status: :done} = issue, _v),
    do: "Done on #{day(issue.completed_at || issue.updated_at)}."

  defp clear_line(%{status: :todo}, %{assignee: %{name: name}}), do: "Queued for #{name}."
  defp clear_line(_issue, _v), do: nil

  defp question_title(:ask_user_questions, name, n) when n > 1, do: "Answer #{name}'s questions"
  defp question_title(:ask_user_questions, name, _n), do: "Answer #{name}'s question"
  defp question_title(:request_confirmation, name, _n), do: "Confirm #{name}'s request"
  defp question_title(_kind, name, _n), do: "Review #{name}'s proposed tasks"

  # The OwnerAttention projection carries the vetted options; without an item,
  # the stored payload's question text only.
  defp questions(%{kind: :ask_user_questions} = interaction, item) do
    case item do
      %{kind: :interaction, source_id: id, questions: [_ | _] = qs} when id == interaction.id ->
        qs

      _ ->
        (interaction.payload || %{})
        |> Map.get("questions", [])
        |> List.wrap()
        |> Enum.flat_map(fn
          %{"question" => q} when is_binary(q) and q != "" -> [%{question: q, options: []}]
          _ -> []
        end)
    end
  end

  defp questions(_interaction, _item), do: []

  defp task_title(%{"title" => title}) when is_binary(title), do: title
  defp task_title(_task), do: "Untitled task"

  # The newest agent comment's first line, as the reviewer's evidence.
  defp latest_agent_note(issue, agents) do
    issue
    |> comments()
    |> Enum.filter(&(&1.author_type == "agent"))
    |> Enum.max_by(& &1.inserted_at, DateTime, fn -> nil end)
    |> case do
      nil ->
        nil

      comment ->
        text = CymphoWeb.IssueLive.Show.Helpers.compact_body(comment.body, 160)
        text && %{by: agent_name(agents, comment.author_id), text: text}
    end
  end

  # The last note written up to the moment the task was cancelled.
  defp last_note_before(issue, v) do
    until = issue.cancelled_at || issue.updated_at

    issue
    |> comments()
    |> Enum.filter(&(DateTime.compare(to_dt(&1.inserted_at), DateTime.add(until, 60)) != :gt))
    |> Enum.max_by(& &1.inserted_at, DateTime, fn -> nil end)
    |> case do
      nil ->
        nil

      comment ->
        text = CymphoWeb.IssueLive.Show.Helpers.compact_body(comment.body, 160)
        text && %{text: text, by: author(comment, v.agents, v.names)}
    end
  end

  # HumanReview sends a CEO task to the CTO and a CTO task to an engineer
  # (issues/human_review.ex `return_role/1`).
  defp return_role("ceo"), do: "CTO"
  defp return_role(role) when role in ["cto", "", nil], do: "engineer"
  defp return_role(role), do: String.replace(role, "_", " ")

  defp people(issue, assigns) do
    user = assigns[:current_user]
    authors = assigns[:comment_authors] || %{}

    lookup = fn
      nil ->
        nil

      id ->
        cond do
          user && user.id == id -> first_name(user.name)
          name = Map.get(authors, id) -> first_name(name)
          true -> nil
        end
    end

    agent_creator =
      Enum.find_value(assigns.all_agents, fn a -> a.id == issue.created_by_agent_id && a.name end)

    %{
      creator: lookup.(issue.created_by_user_id) || agent_creator,
      assignee_user: lookup.(issue.assignee_user_id),
      users: authors
    }
  end

  defp author(%{author_type: type, author_id: id}, agents, _names) when type in ["agent", :agent],
    do: agent_name(agents, id)

  defp author(%{author_type: type}, _agents, _names) when type in ["system", :system],
    do: "Cympho"

  defp author(%{author_id: id}, _agents, names) do
    case Map.get(names.users, id) do
      name when is_binary(name) and name != "" -> first_name(name)
      _ -> "Someone"
    end
  end

  defp agent_name(agents, id) do
    case Map.get(agents, id) do
      %{name: name} when is_binary(name) -> name
      _ -> "Someone"
    end
  end

  defp first_name(name) when is_binary(name) do
    case String.split(name) do
      [first | _] -> first
      [] -> name
    end
  end

  defp first_name(_name), do: nil

  defp initials(name) when is_binary(name), do: name |> String.slice(0, 2) |> String.upcase()
  defp initials(_name), do: "?"

  # Comments are preloaded by Issues.get_company_issue/2; an issue returned by an
  # update keeps them, but never trust a bare struct.
  defp comments(%{comments: comments}) when is_list(comments), do: comments
  defp comments(_issue), do: []

  defp project_name(%{project: %{name: name}}), do: name
  defp project_name(_issue), do: nil

  defp goal_title(%{goal: %{title: title}}), do: title
  defp goal_title(_issue), do: nil

  defp loaded(%Ecto.Association.NotLoaded{}), do: nil
  defp loaded(value), do: value

  defp run_minutes(%{started_at: %DateTime{} = started} = run) do
    ended = run.completed_at || DateTime.utc_now()
    max(div(DateTime.diff(ended, started) + 59, 60), 1)
  end

  defp run_minutes(_run), do: nil

  # Glossary run words.
  defp run_word(status) when status in @finished, do: "finished"
  defp run_word("failed"), do: "failed"
  defp run_word("timed_out"), do: "timed out"
  defp run_word("running"), do: "working"
  defp run_word("cancelled"), do: "cancelled"
  defp run_word(_waiting), do: "waiting to start"

  defp positive(%Decimal{} = d), do: if(Decimal.gt?(d, 0), do: d)
  defp positive(_value), do: nil

  defp present(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp present(_value), do: nil

  defp count(1, word), do: "1 #{word}"
  defp count(n, word), do: "#{n} #{word}s"

  defp to_dt(%DateTime{} = at), do: at
  defp to_dt(%NaiveDateTime{} = at), do: DateTime.from_naive!(at, "Etc/UTC")

  defp clock(nil), do: ""
  defp clock(at), do: at |> to_dt() |> Calendar.strftime("%H:%M")

  defp day(nil), do: ""
  defp day(at), do: at |> to_dt() |> Calendar.strftime("%a %-d %b")

  # "Mon 15:24" within the week, else "19 Oct 15:24".
  defp stamp(nil), do: ""
  defp stamp(at), do: "#{stamp_day(at)} #{clock(at)}"

  defp stamp_day(at) do
    at = to_dt(at)

    if DateTime.diff(DateTime.utc_now(), at, :day) < 6,
      do: Calendar.strftime(at, "%a"),
      else: Calendar.strftime(at, "%-d %b")
  end

  defp doc_file,
    do:
      ~S|<svg class="file" viewBox="0 0 34 42" aria-hidden="true"><path class="fp" d="M4 1.5h17.5L31.5 11.5V38a2.5 2.5 0 0 1-2.5 2.5H4A2.5 2.5 0 0 1 1.5 38V4A2.5 2.5 0 0 1 4 1.5z" stroke-width="1.2"/><path class="ff" d="M21.5 1.5v7.5a2.5 2.5 0 0 0 2.5 2.5h7.5" stroke-width="1.2"/><path class="fm" d="M8 19h12M8 24h17M8 29h14" stroke-width="2" stroke-linecap="round"/></svg>|

  defp code_file,
    do:
      ~S|<svg class="file" viewBox="0 0 34 42" aria-hidden="true"><path class="fp" d="M4 1.5h17.5L31.5 11.5V38a2.5 2.5 0 0 1-2.5 2.5H4A2.5 2.5 0 0 1 1.5 38V4A2.5 2.5 0 0 1 4 1.5z" stroke-width="1.2"/><path class="ff" d="M21.5 1.5v7.5a2.5 2.5 0 0 0 2.5 2.5h7.5" stroke-width="1.2"/><path class="fm" d="m12.5 21-4 4 4 4M20.5 21l4 4-4 4M17.75 19.5l-2 11" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>|
end
