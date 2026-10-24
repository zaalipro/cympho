defmodule CymphoWeb.NextStep do
  @moduledoc """
  The Next step (build-spec §2.2): one owner item drawn as the r3 pair, the
  problem card and the resolution card that holds the page's one primary, and
  every other item as a closed Needs-you row. One decision reads the same on
  every page, so its copy lives here once: verb-first titles, the effect
  library (v2 spec §1.3), and a primary that names where it goes when the
  decision is made on another page (S7).

  Pages pass `Cympho.OwnerAttention` items in `OwnerAttention.owner_order/1`,
  their own path as `from` (links into deep pages carry `?from=`), the
  company's agent names by id (a review is the work of the task's assignee),
  and `CymphoWeb.TeamRail.spending/1` for the company-stopped state.

  The resolution card sends `resume_agent` (`phx-value-id`),
  `respond_questions` (read it with `answer_from_params/1`), and for an owner
  sign-off `accept_owner_verification` / `request_owner_revision`
  (`phx-value-issue-id`).
  """
  use Phoenix.Component

  import CymphoWeb.Components.R3
  import CymphoWeb.Format, only: [money: 1, window: 1]

  alias Cympho.Agents.Agent
  alias Cympho.OwnerAttention

  @words %{
    stopped: "Spending",
    problem: "Problem",
    question: "Question",
    review: "Review",
    approval: "Approval"
  }
  @icons %{
    stopped: "i-stop",
    problem: "i-stop",
    question: "i-question",
    review: "i-doc-check",
    approval: "i-shield"
  }
  @tiles %{stopped: :problem, problem: :problem, question: :question}

  @doc """
  The answer of a Next-step question form: the chosen option, or the own
  answer when the own row (or no row) is chosen. `{:ok, interaction_id, text}`
  or `{:error, :empty}`.
  """
  def answer_from_params(%{"_id" => id} = params) when is_binary(id) do
    text =
      case params["response"] do
        choice when choice in [nil, "", "own"] -> params["own_response"]
        choice -> choice
      end

    case text |> to_string() |> String.trim() do
      "" -> {:error, :empty}
      answer -> {:ok, id, answer}
    end
  end

  def answer_from_params(_params), do: {:error, :empty}

  ## ── The pair ──────────────────────────────────────────────────

  attr :item, :map, required: true
  attr :from, :string, default: "/"
  attr :agents, :map, default: %{}, doc: "agent id => name"
  attr :spending, :map, default: nil, doc: "CymphoWeb.TeamRail.spending/1"

  @doc "The Next step for one owner item."
  def pair(assigns) do
    assigns = assign(assigns, :v, view(assigns.item, assigns.agents, assigns.from))

    ~H"""
    <%= case @v.layout do %>
      <% :stopped -> %>
        <.paused_step spending={@spending} />
      <% :question -> %>
        <.question_pair v={@v} />
      <% :generic -> %>
        <.generic_pair v={@v} />
    <% end %>
    """
  end

  attr :v, :map, required: true

  defp generic_pair(assigns) do
    ~H"""
    <.next_step>
      <:problem>
        <.problem_card title={@v.title}>
          <:eyebrow><.eyebrow word={@v.word} time={@v.time} /></:eyebrow>
          <p :if={@v.lead} class="obj"><b>{@v.lead}</b>{@v.rest}</p>
          <.run_bars :if={@v.runs != []} runs={@v.runs} label={@v.runs_label} />
          <.tick_meter :if={@v.meter} percent={@v.meter} />
          <:foot :if={@v.foot}><.foot foot={@v.foot} /></:foot>
        </.problem_card>
      </:problem>
      <:resolution>
        <.ink_card heading={@v.heading} data-testid={@v.testid}>
          <.consequences :if={@v.effects != []} rows={@v.effects} />
          <.ink_note :if={@v.note}>{@v.note}</.ink_note>
          <.ink_foot verb={@v.verb}>
            <:secondary :if={@v.ghost}><.action pill={:ghost} action={@v.ghost} /></:secondary>
            <:primary><.action pill={:primary} action={@v.primary} /></:primary>
          </.ink_foot>
        </.ink_card>
      </:resolution>
    </.next_step>
    """
  end

  attr :v, :map, required: true

  # A question parks its task; its answer goes back from the resolution card itself.
  defp question_pair(assigns) do
    ~H"""
    <.next_step>
      <:problem>
        <.problem_card title={@v.title}>
          <:eyebrow><.eyebrow word={@v.word} time={@v.time} /></:eyebrow>
          <blockquote class="quote" id="ns-q">
            <.quote_mark />
            <p>{@v.question}</p>
          </blockquote>
          <:foot><.foot foot={@v.foot} /></:foot>
        </.problem_card>
      </:problem>
      <:resolution>
        <.ink_card form={@v.title} id="ns-answer" phx-submit="respond_questions">
          <input type="hidden" name="_id" value={@v.interaction_id} />
          <.option_rows
            :if={@v.options != []}
            name="response"
            legend="Your answer"
            items={Enum.map(@v.options, &%{value: &1, label: &1})}
            describedby="ns-q"
          />
          <fieldset :if={@v.options == []} class="opts" aria-describedby="ns-q">
            <legend>Your answer</legend>
            <div class="own-box open">
              <label class="sr" for="ns-own">Your answer</label>
              <textarea id="ns-own" name="own_response" rows="2"></textarea>
            </div>
          </fieldset>
          <.ink_note>{@v.note}</.ink_note>
          <.ink_foot verb="send">
            <:primary>
              <.primary_pill type="submit">Send answer</.primary_pill>
            </:primary>
          </.ink_foot>
        </.ink_card>
      </:resolution>
    </.next_step>
    """
  end

  attr :word, :string, required: true
  attr :time, :string, default: nil

  defp eyebrow(assigns) do
    ~H"""
    Next step<span aria-hidden="true">·</span>
    <span>
      {@word}<span :if={@time}><span aria-hidden="true"> · </span><span class="mono">{@time}</span></span>
    </span>
    """
  end

  attr :foot, :map, required: true

  defp foot(assigns) do
    ~H"""
    <%= case @foot.left do %>
      <% {:issue, identifier, href, nil} -> %>
        <span>On <.link class="ul mono" navigate={href}>{identifier}</.link></span>
      <% {:issue, identifier, href, {amount, words}} -> %>
        <span>
          On
          <.link class="ul mono" navigate={href}>{identifier}</.link><span aria-hidden="true"> · </span><span class="mono">{amount}</span> {words}
        </span>
      <% {:who, initials, name, role} -> %>
        <span class="who">
          <span class="tile-ag sm" aria-hidden="true">{initials}</span><span><b>{name}</b><span :if={
            role
          }><span aria-hidden="true"> · </span>{role}</span></span>
        </span>
      <% {:text, text} -> %>
        <span>{text}</span>
    <% end %>
    <.link :if={@foot.right} class="ul" navigate={elem(@foot.right, 1)}>
      {elem(@foot.right, 0)}
    </.link>
    """
  end

  attr :pill, :atom, required: true, values: [:primary, :ghost]
  attr :action, :any, required: true

  defp action(%{action: {:link, label, href}} = assigns) do
    assigns = assign(assigns, label: label, href: href)

    ~H"""
    <.primary_pill :if={@pill == :primary} navigate={@href}>{@label}</.primary_pill>
    <.ghost_pill :if={@pill == :ghost} navigate={@href}>{@label}</.ghost_pill>
    """
  end

  defp action(%{action: {:event, label, attrs}} = assigns) do
    assigns = assign(assigns, label: label, attrs: attrs)

    ~H"""
    <.primary_pill :if={@pill == :primary} {@attrs}>{@label}</.primary_pill>
    <.ghost_pill :if={@pill == :ghost} {@attrs}>{@label}</.ghost_pill>
    """
  end

  ## ── Company-wide pairs (build-spec §2.2, one copy each) ──────

  attr :spending, :map, default: nil, doc: "CymphoWeb.TeamRail.spending/1"

  @doc "The company is paused at its spending limit."
  def paused_step(assigns) do
    assigns =
      assign(assigns,
        limit: assigns.spending && assigns.spending.limit,
        days: assigns.spending && assigns.spending.days
      )

    ~H"""
    <.next_step>
      <:problem>
        <.problem_card title="Raise the spending limit">
          <:eyebrow>
            Next step<span aria-hidden="true"> · </span>Company paused
          </:eyebrow>
          <p :if={@limit} class="obj">
            <b>Agents stopped:</b>
            the <span class="mono">{money(@limit)}</span>
            limit for the last {window(@days)} was reached.
          </p>
          <p :if={!@limit} class="obj"><b>Agents stopped:</b> the spending limit was reached.</p>
          <.tick_meter percent={100} class="full">
            <:legend><span class="z st">agents stop</span></:legend>
          </.tick_meter>
        </.problem_card>
      </:problem>
      <:resolution>
        <.ink_card heading="After you change it">
          <.consequences rows={[{:idle, "Press Resume agents to start work again."}]} />
          <.ink_foot verb="change">
            <:secondary>
              <.ghost_pill navigate="/costs">Open Spending</.ghost_pill>
            </:secondary>
            <:primary>
              <.primary_pill navigate="/costs">Change limit</.primary_pill>
            </:primary>
          </.ink_foot>
        </.ink_card>
      </:resolution>
    </.next_step>
    """
  end

  @doc "Agents are switched off on this server and nothing needs the owner (plan §11 D1)."
  def server_off_step(assigns) do
    ~H"""
    <.next_step>
      <:problem>
        <.problem_card title="Turn agents on">
          <:eyebrow>Next step<span aria-hidden="true"> · </span>Agents off</:eyebrow>
          <p class="obj">Agents are switched off on this server. You can still plan and answer.</p>
        </.problem_card>
      </:problem>
      <:resolution>
        <.ink_card heading="Until it changes">
          <.ink_note>Nothing runs here until the server setting changes.</.ink_note>
          <div class="ink-f">
            <details class="howto">
              <summary class="pw">
                How to turn agents on<span class="nub"><.r3_icon name="i-chev-down" /></span>
              </summary>
              <p>
                Whoever runs this server turns the orchestrator on; agents then pick up work again.
              </p>
            </details>
          </div>
        </.ink_card>
      </:resolution>
    </.next_step>
    """
  end

  attr :title, :string, default: "Nothing needs you"

  @doc "Nothing needs the owner: the page's own title, and New task as the one primary."
  def all_clear(assigns) do
    ~H"""
    <.next_step>
      <:problem>
        <.problem_card title={@title}>
          <:eyebrow>All clear</:eyebrow>
        </.problem_card>
      </:problem>
      <:resolution>
        <.ink_card heading="After you add it">
          <.consequences rows={[
            {:done,
             "Cympho gives it to an agent with the right role, or keeps it in Later if nobody is free."}
          ]} />
          <.ink_foot verb="add">
            <:primary>
              <.primary_pill href="/issues/new" data-quick-create-trigger>New task</.primary_pill>
            </:primary>
          </.ink_foot>
        </.ink_card>
      </:resolution>
    </.next_step>
    """
  end

  ## ── Needs-you rows ────────────────────────────────────────────

  attr :item, :map, required: true
  attr :n, :integer, required: true, doc: "position, for unique ids"
  attr :from, :string, default: "/"
  attr :agents, :map, default: %{}
  attr :idp, :string, default: "ny"

  @doc "A closed Needs-you row: kind tile, verb-first title, meta, one verb."
  def row(assigns) do
    assigns = assign(assigns, :v, view(assigns.item, assigns.agents, assigns.from))

    ~H"""
    <.needs_row
      id={"#{@idp}#{@n}"}
      kind={Map.get(tiles(), @v.owner, :neutral)}
      icon={Map.fetch!(icons(), @v.owner)}
      title={@v.title}
      verb={@v.row_verb}
      navigate={@v.row_href}
    >
      {@v.word}
      <%= for part <- @v.meta ++ [@v.time && {:mono, @v.time}], part do %>
        <span aria-hidden="true"> · </span>
        <%= case part do %>
          <% {:mono, text} -> %>
            <span class="mono">{text}</span>
          <% text -> %>
            {text}
        <% end %>
      <% end %>
    </.needs_row>
    """
  end

  defp tiles, do: @tiles
  defp icons, do: @icons

  ## ── One item, in the owner's words ────────────────────────────

  defp view(item, agents, from) do
    owner = OwnerAttention.owner_kind(item)
    issue = item.issue

    base = %{
      owner: owner,
      word: Map.fetch!(@words, owner),
      time: stamp(item.inserted_at),
      title: nil,
      lead: nil,
      rest: nil,
      runs: [],
      runs_label: nil,
      meter: nil,
      foot:
        issue && %{left: {:issue, identifier(issue), issue_href(issue, from), nil}, right: nil},
      heading: nil,
      effects: [],
      note: nil,
      ghost: nil,
      primary: nil,
      verb: "open",
      testid: nil,
      layout: :generic,
      meta: Enum.reject([issue && {:mono, identifier(issue)}, agent_name(item)], &is_nil/1),
      row_verb: "Details",
      row_href: (issue && issue_href(issue, from)) || with_from(item.target_path, from)
    }

    Map.merge(base, details(item, issue, agents, from))
  end

  # An owner sign-off a page drew in as a review (DashboardLive): accept or revise here.
  defp details(%{signoff: decision}, issue, _agents, from) do
    id = identifier(issue)
    ceo = if decision.assignee_name in [nil, "Unassigned"], do: nil, else: decision.assignee_name

    %{
      title: if(ceo, do: "Review #{ceo}'s update", else: "Review the owner update"),
      lead: decision.issue_title,
      rest: decision.owner_update && " — #{decision.owner_update}",
      heading: "Decide on #{id}",
      effects:
        [{:done, "After you accept: #{id} is marked Done."}] ++
          if(ceo,
            do: [{:idle, "After you ask for a revision: #{id} goes back to To do for #{ceo}."}],
            else: []
          ),
      verb: "accept",
      testid: "dashboard-owner-signoff-actions",
      ghost:
        {:event, "Request revision",
         [
           "phx-click": "request_owner_revision",
           "phx-value-issue-id": decision.issue_id,
           "data-confirm":
             "Request a CEO revision, reopen this issue to To Do, and queue focused dispatch?"
         ]},
      primary:
        {:event, "Accept and close",
         [
           "phx-click": "accept_owner_verification",
           "phx-value-issue-id": decision.issue_id,
           "data-confirm": "Accept this CEO owner update and close the issue?"
         ]},
      meta: Enum.reject([{:mono, id}, ceo], &is_nil/1),
      row_verb: "Review",
      row_href: issue_href(issue, from)
    }
  end

  defp details(%{kind: :agent_paused, agent: agent} = item, issue, _agents, from) do
    {lead, rest} = split_summary(item.summary)
    waiting? = issue != nil and is_nil(issue.assignee_id)
    id = issue && identifier(issue)
    agent_href = with_from("/agents/#{agent.id}", from)

    %{
      title: item.title,
      lead: lead,
      rest: rest,
      runs: item.runs,
      runs_label: id && "#{agent.name}'s last #{length(item.runs)} runs on #{id}, in minutes",
      foot:
        issue &&
          %{
            left:
              {:issue, id, issue_href(issue, from),
               {money(runs_cost(item.runs)), "for these runs"}},
            right: {"Open #{agent.name}", agent_href}
          },
      heading: "After you resume",
      effects:
        [{:done, "#{agent.name} can take new work."}] ++
          if(waiting?,
            do: [{:idle, "#{id} stays unassigned until someone retries it."}],
            else: []
          ),
      note: waiting? && "To restart #{id}, open it and choose who retries it.",
      verb: "resume",
      ghost: issue && {:link, "Open #{id}", issue_href(issue, from)},
      primary: {:event, item.title, ["phx-click": "resume_agent", "phx-value-id": agent.id]},
      row_href: agent_href
    }
  end

  defp details(%{kind: :interaction} = item, issue, _agents, from) do
    name = agent_name(item) || "The agent"
    id = identifier(issue)
    asks = item.interaction_kind == :ask_user_questions
    questions = item.questions

    title =
      cond do
        asks and length(questions) > 1 -> "Answer #{name}'s questions"
        asks -> "Answer #{name}'s question"
        item.interaction_kind == :request_confirmation -> "Confirm #{name}'s request"
        true -> "Review #{name}'s proposed tasks"
      end

    common = %{
      title: title,
      row_verb: if(asks, do: "Answer", else: "Decide"),
      foot: %{
        left: {:who, initials(name), name, role(item.agent)},
        right: {"Open #{id}", issue_href(issue, from)}
      }
    }

    case questions do
      [%{question: question, options: options}] when asks ->
        Map.merge(common, %{
          layout: :question,
          question: question,
          options: options,
          interaction_id: item.source_id,
          note:
            "After you send: #{name} gets your answer as a comment and is asked to carry on with #{id}."
        })

      _ ->
        Map.merge(common, %{
          lead: item.summary,
          heading: "Decide on #{id}",
          note: interaction_note(item.interaction_kind, id),
          primary:
            {:link, "Open #{id} to #{if asks, do: "answer", else: "decide"}",
             issue_href(issue, from)}
        })
    end
  end

  defp details(%{kind: :review_queue} = item, issue, agents, from) do
    id = identifier(issue)
    person = Map.get(agents, issue.assignee_id) || agent_name(item) || "the team"
    role = issue.assigned_role && ", for the next free #{humanize(issue.assigned_role)}"

    %{
      title: "Review #{person}'s work",
      lead: issue.title,
      heading: "Decide on #{id}",
      effects: [
        {:done, "After you accept: #{id} is marked Done."},
        {:idle, "After you send it: #{id} goes back to To do with your note#{role}."}
      ],
      primary: {:link, "Open #{id} to decide", issue_href(issue, from)},
      meta: [{:mono, id}, person],
      row_verb: "Review"
    }
  end

  defp details(%{kind: :board_approval} = item, _issue, _agents, from) do
    href = with_from(item.target_path, from)

    %{
      title: item.title,
      lead: words(item.summary, 25),
      foot: agent_name(item) && %{left: {:text, "Requested by #{agent_name(item)}"}, right: nil},
      heading: "Cast your vote",
      note: "On the vote page you approve or deny; your reason is saved with your vote.",
      primary: {:link, "Open vote", href},
      row_verb: "Open vote",
      row_href: href
    }
  end

  defp details(%{kind: :approval} = item, _issue, _agents, from) do
    href = with_from(item.target_path, from)
    name = agent_name(item)

    %{
      title: if(name, do: "Decide on #{name}'s request", else: "Decide on a request"),
      lead: item.title,
      rest: item.summary && " — #{words(item.summary, 20)}",
      heading: "Your decision",
      note: "On the approval page you approve or reject it.",
      primary: {:link, "Open approval", href},
      row_verb: "Open",
      row_href: href
    }
  end

  defp details(%{kind: :budget_incident} = item, _issue, _agents, _from) do
    %{
      layout: if(OwnerAttention.owner_kind(item) == :stopped, do: :stopped, else: :generic),
      title:
        if(item.event_type == "budget_exceeded",
          do: "Raise the spending limit",
          else: "Check spending"
        ),
      lead: item.summary,
      heading: "Before agents stop",
      note: "On Spending you see where the money went and what the limit is.",
      primary: {:link, "Open Spending", "/costs"},
      row_href: "/costs"
    }
  end

  defp details(%{kind: :failed_run} = item, issue, _agents, from) do
    id = identifier(issue)
    name = agent_name(item) || "The agent"

    %{
      title: "See why #{id} stopped",
      lead: "#{name}'s last run failed",
      rest: " on #{issue.title}.",
      heading: "Decide on #{id}",
      note: "On #{id} you see what happened and decide whether to retry.",
      primary: {:link, "Open #{id}", issue_href(issue, from)}
    }
  end

  defp details(%{kind: :stuck_issue} = item, issue, _agents, from) do
    id = identifier(issue)
    [label | _] = String.split(item.title, " · ", parts: 2)

    %{
      title: "Check on #{id}",
      lead: label,
      rest: " — #{issue.title}.",
      heading: "Decide on #{id}",
      note: "On #{id} you can reassign it or check on its agent.",
      primary: {:link, "Open #{id}", issue_href(issue, from)}
    }
  end

  defp details(%{kind: :human_action}, issue, _agents, from) do
    id = identifier(issue)
    blocked? = issue.status == :blocked

    %{
      title: if(blocked?, do: "Unblock #{id}", else: "Pick up #{id}"),
      lead: issue.title,
      rest: if(blocked?, do: " is blocked.", else: " is assigned to you."),
      heading: "Decide on #{id}",
      note:
        if(blocked?,
          do: "On #{id} you see what it is waiting for.",
          else: "On #{id} you see the brief and the thread."
        ),
      primary: {:link, "Open #{id}", issue_href(issue, from)},
      row_verb: "Open"
    }
  end

  defp interaction_note(:request_confirmation, id), do: "On #{id} you confirm or decline it."

  defp interaction_note(:suggest_tasks, id),
    do: "On #{id} you accept or reject the proposed tasks."

  defp interaction_note(_kind, id), do: "On #{id} you answer each question."

  ## ── Helpers ───────────────────────────────────────────────────

  # "Mira stopped after 3 failed attempts — timed out." → bold lead, then the rest.
  defp split_summary(summary) when is_binary(summary) do
    case String.split(summary, " — ", parts: 2) do
      [lead, rest] -> {lead, " — " <> rest}
      [lead] -> {lead, nil}
    end
  end

  defp split_summary(_summary), do: {nil, nil}

  defp runs_cost(runs) do
    Enum.reduce(runs, Decimal.new(0), fn run, sum -> Decimal.add(sum, run.cost_usd || 0) end)
  end

  defp agent_name(%{agent: %{name: name}}) when is_binary(name), do: name
  defp agent_name(_item), do: nil

  defp role(%Agent{role: role}) when not is_nil(role), do: Agent.role_label(role)
  defp role(_agent), do: nil

  defp initials(name), do: name |> String.slice(0, 2) |> String.upcase()

  defp identifier(%{identifier: id}) when is_binary(id), do: id
  defp identifier(_issue), do: "the task"

  defp issue_href(issue, from), do: with_from("/issues/#{issue.id}", from)

  defp with_from(nil, _from), do: nil
  defp with_from(path, nil), do: path
  defp with_from(path, from), do: path <> "?from=" <> from

  defp humanize(value), do: value |> to_string() |> String.replace("_", " ")

  defp words(nil, _count), do: nil

  defp words(text, count) do
    case String.split(text) do
      parts when length(parts) > count -> Enum.join(Enum.take(parts, count), " ") <> "…"
      _ -> text
    end
  end

  # A clock time within the last day, else the day: "04:12", "Mon 19 Oct".
  defp stamp(%DateTime{} = at) do
    if DateTime.diff(DateTime.utc_now(), at, :hour) < 24,
      do: Calendar.strftime(at, "%H:%M"),
      else: Calendar.strftime(at, "%a %-d %b")
  end

  defp stamp(%NaiveDateTime{} = at), do: at |> DateTime.from_naive!("Etc/UTC") |> stamp()
  defp stamp(_at), do: nil
end
