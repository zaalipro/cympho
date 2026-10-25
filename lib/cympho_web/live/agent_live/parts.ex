defmodule CymphoWeb.AgentLive.Parts do
  @moduledoc """
  What the r3 Team (`AgentLive.Index`) and Agent (`AgentLive.Show`) pages
  share: an agent's owner-facing state word, the owner items "for" an agent,
  run rows, and the pairs only these pages draw (the Agent page's own Resume
  and Retry, and the two all-clear states). Built from
  `CymphoWeb.Components.R3`, so `r3.css` styles them.
  """
  use Phoenix.Component

  import CymphoWeb.Components.R3

  @doc """
  An agent's state word with its shape (spec §1.5). A paused or failed agent
  stays Stopped even with a run still marked running; otherwise a running run
  means Working, whatever the stored status says (a delegated run).
  """
  def status(%{status: :error}, _running?), do: {:stopped, "Stopped"}
  def status(%{status: :paused}, _running?), do: {:stopped, "Paused"}
  def status(_agent, true), do: {:working, "Working"}
  def status(%{status: status}, _) when status in [:running, :active], do: {:working, "Working"}
  def status(%{status: :pending_approval}, _), do: {:waiting, "Waiting for your approval"}
  def status(%{status: :offline}, _), do: {:idle, "Offline"}
  def status(%{status: :terminated}, _), do: {:idle, "Terminated"}
  def status(_agent, _running?), do: {:idle, "Idle"}

  @doc "The agent an owner item counts for: the rule behind the \"N for you\" chips."
  defdelegate for_you_agent_id(item), to: Cympho.OwnerAttention

  @doc "Dollars and cents, always both: agent and run costs (\"$19.40\", \"$0.00\")."
  def usd(%Decimal{} = amount),
    do: "$" <> (amount |> Decimal.round(2) |> Decimal.to_string(:normal))

  def usd(nil), do: usd(Decimal.new(0))

  def initials(name) when is_binary(name), do: name |> String.slice(0, 2) |> String.upcase()
  def initials(_name), do: "?"

  @doc "A clock time within the last day, else the day: \"03:52\", \"Mon 19 Oct\" (UTC, as Home)."
  def stamp(%DateTime{} = at) do
    if DateTime.diff(DateTime.utc_now(), at, :hour) < 24,
      do: Calendar.strftime(at, "%H:%M"),
      else: Calendar.strftime(at, "%a %-d %b")
  end

  def stamp(_at), do: nil

  ## ── Runs ──────────────────────────────────────────────────────

  @doc """
  One run as a row: `title` is the row's link text, `href` opens the run in
  its agent's History. The run needs its `issue` loaded only for the caller's title.
  """
  def run_row(run, title, href) do
    started = run.started_at || run.inserted_at
    ended = run.completed_at
    seconds = if started, do: max(DateTime.diff(ended || DateTime.utc_now(), started), 0), else: 0

    %{
      id: run.id,
      title: title,
      href: href,
      status: run.status,
      failed?: run.status in ~w(failed timed_out),
      word: run_word(run.status),
      range: run_range(started, ended, run.status),
      minutes: max(div(seconds + 59, 60), 1),
      cost: usd(run.cost_usd)
    }
  end

  defp run_range(nil, _ended, _status), do: nil
  defp run_range(started, nil, "running"), do: "#{clock(started)} → now"
  defp run_range(started, nil, _status), do: clock(started)
  defp run_range(started, ended, _status), do: "#{clock(started)} → #{clock(ended)}"

  defp clock(at), do: Calendar.strftime(at, "%H:%M")

  defp run_word("failed"), do: "Failed"
  defp run_word("timed_out"), do: "Timed out"
  defp run_word(status) when status in ~w(completed succeeded), do: "Finished"
  defp run_word("running"), do: "Working"
  defp run_word("cancelled"), do: "Cancelled"
  defp run_word(_status), do: "Waiting to start"

  attr :rows, :list, required: true, doc: "run_row/3 maps, newest first"
  attr :patch, :boolean, default: false, doc: "rows open the run on the same LiveView"

  @doc "Run rows on one shared minute axis; failed and timed-out runs are hatched (Agent 088, 016)."
  def run_list(assigns) do
    # An even axis, so its middle mark is a whole minute (0 · 15 · 30 min).
    longest = assigns.rows |> Enum.map(& &1.minutes) |> Enum.max(fn -> 2 end)
    axis = longest + rem(longest, 2)

    assigns =
      assign(assigns,
        axis: axis,
        half: div(axis, 2),
        widths: Map.new(assigns.rows, &{&1.id, Float.round(&1.minutes * 100 / axis, 2)})
      )

    ~H"""
    <ol class="runs">
      <li :for={row <- @rows} class="run">
        <span :if={row.failed?} class="sq hatch" aria-hidden="true"></span>
        <.status_glyph :if={!row.failed?} kind={row_kind(row.status)} big />
        <div class="run-main">
          <.link class="rt2" patch={@patch && row.href} navigate={!@patch && row.href}>
            {row.title}
          </.link>
          <p class="run-sub">
            <span class={["st", word_class(row.status)]}>{row.word}</span><span
              :if={row.range}
              class="mono"
            >{row.range}</span>
          </p>
        </div>
        <span class="rb-track" aria-hidden="true">
          <span
            class={["rb-bar", (row.failed? && "hatch") || "solid"]}
            style={"width:#{Map.fetch!(@widths, row.id)}%;min-width:10px"}
          >
          </span>
        </span>
        <p class="run-cost">{row.minutes} min<span>{row.cost}</span></p>
      </li>
    </ol>
    <div class="axis-row" aria-hidden="true">
      <span></span><span></span><span class="rb-axis mono"><span>0</span><span>{@half}</span><span>{@axis} min</span></span>
    </div>
    """
  end

  defp row_kind("running"), do: :working
  defp row_kind(status) when status in ~w(completed succeeded), do: :done
  defp row_kind(_status), do: :idle

  defp word_class("running"), do: "wk"
  defp word_class(status) when status in ~w(failed timed_out), do: nil
  defp word_class(_status), do: "ok"

  ## ── Pairs only these pages draw ───────────────────────────────

  attr :item, :map, required: true, doc: "the agent's :agent_paused OwnerAttention item"

  @doc """
  Resume on the agent's own page (mockup agent.html): the runs sit in Recent
  runs below, so the problem card carries the count and the stored reason
  instead of run bars and an "Open {agent}" link.
  """
  def paused_pair(assigns) do
    item = assigns.item
    issue = item.issue
    id = issue && issue.identifier
    waiting? = issue != nil and is_nil(issue.assignee_id)

    assigns =
      assign(assigns,
        name: item.agent.name,
        id: id,
        issue: issue,
        waiting?: waiting?,
        lead: paused_lead(item.runs, id),
        rest: paused_rest(item.runs, id, item.summary)
      )

    ~H"""
    <.next_step>
      <:problem>
        <.problem_card title={@item.title}>
          <:eyebrow>Next step<span aria-hidden="true"> · </span>Problem</:eyebrow>
          <p class="obj"><b :if={@lead}>{@lead}</b>{@rest}</p>
          <details
            :if={@item.diagnostic}
            id="paused-reason"
            class="reason"
            phx-mounted={Phoenix.LiveView.JS.ignore_attributes("open")}
          >
            <summary>
              <span>Reason as Cympho stored it</span> <.r3_icon name="i-chev-down" class="ico s14" />
            </summary>
            <p>{@item.diagnostic}</p>
          </details>
        </.problem_card>
      </:problem>
      <:resolution>
        <.ink_card heading="After you resume">
          <.consequences rows={
            [{:done, "#{@name} can take new work."}] ++
              if(@waiting?,
                do: [{:idle, "#{@id} stays unassigned until someone retries it."}],
                else: []
              )
          } />
          <.ink_note :if={@waiting?}>To restart {@id}, open it and choose who retries it.</.ink_note>
          <.ink_foot verb="resume">
            <:secondary :if={@issue}>
              <.ghost_pill navigate={"/issues/#{@issue.id}"}>Open {@id}</.ghost_pill>
            </:secondary>
            <:primary>
              <.primary_pill phx-click="resume_agent" phx-value-id={@item.agent.id}>
                {@item.title}
              </.primary_pill>
            </:primary>
          </.ink_foot>
        </.ink_card>
      </:resolution>
    </.next_step>
    """
  end

  # "Last 3 runs on NW-10 ended without progress:" + " 2 failed, 1 timed out."
  defp paused_lead([], _id), do: nil
  defp paused_lead(_runs, nil), do: nil
  defp paused_lead([_one], id), do: "The last run on #{id} ended without progress:"
  defp paused_lead(runs, id), do: "Last #{length(runs)} runs on #{id} ended without progress:"

  defp paused_rest(runs, id, _summary) when runs != [] and is_binary(id) do
    counts = Enum.frequencies_by(runs, & &1.status)

    parts =
      Enum.reject(
        [
          counts["failed"] && "#{counts["failed"]} failed",
          counts["timed_out"] && "#{counts["timed_out"]} timed out"
        ],
        &is_nil/1
      )

    " " <> Enum.join(parts, ", ") <> "."
  end

  defp paused_rest(_runs, _id, summary), do: summary

  attr :agent, :map, required: true
  attr :reason, :string, default: nil, doc: "the latest failure as Cympho stored it"

  @doc "An agent stopped in error (no owner item exists for it): a fresh heartbeat."
  def retry_pair(assigns) do
    ~H"""
    <.next_step>
      <:problem>
        <.problem_card title={"Retry #{@agent.name}"}>
          <:eyebrow>Next step<span aria-hidden="true"> · </span>Problem</:eyebrow>
          <p class="obj">
            <b>{@agent.name} stopped in error:</b> the last session did not finish cleanly.
          </p>
          <details
            :if={@reason}
            id="retry-reason"
            class="reason"
            phx-mounted={Phoenix.LiveView.JS.ignore_attributes("open")}
          >
            <summary>
              <span>Reason as Cympho stored it</span> <.r3_icon name="i-chev-down" class="ico s14" />
            </summary>
            <p>{String.slice(@reason, 0, 400)}</p>
          </details>
        </.problem_card>
      </:problem>
      <:resolution>
        <.ink_card heading="After you retry">
          <.consequences rows={[{:idle, "#{@agent.name} picks up its assigned To do work, if any."}]} />
          <.ink_foot verb="retry">
            <:secondary>
              <.ghost_pill patch={"/agents/#{@agent.id}?tab=runs"}>Open History</.ghost_pill>
            </:secondary>
            <:primary>
              <.primary_pill phx-click="run_heartbeat">Retry with heartbeat</.primary_pill>
            </:primary>
          </.ink_foot>
        </.ink_card>
      </:resolution>
    </.next_step>
    """
  end

  attr :agent, :map, required: true

  @doc "Nothing needs the owner on this agent (spec §3.6): open a task already assigned to it."
  def agent_all_clear(assigns) do
    ~H"""
    <.next_step>
      <:problem>
        <.problem_card title="Nothing needed from you">
          <:eyebrow>All clear</:eyebrow>
        </.problem_card>
      </:problem>
      <:resolution>
        <.ink_card>
          <.ink_note>Opens a new task with {@agent.name} already assigned.</.ink_note>
          <.ink_foot verb="assign">
            <:primary>
              <.primary_pill navigate={"/issues/new?assignee_id=#{@agent.id}"}>
                Assign a task
              </.primary_pill>
            </:primary>
          </.ink_foot>
        </.ink_card>
      </:resolution>
    </.next_step>
    """
  end

  attr :title, :string, default: "Everyone is working or ready"

  @doc "No agent is stopped (build-spec §6 state a): Hire, with the library's effect."
  def team_all_clear(assigns) do
    ~H"""
    <.next_step>
      <:problem>
        <.problem_card title={@title}>
          <:eyebrow>All clear</:eyebrow>
        </.problem_card>
      </:problem>
      <:resolution>
        <.ink_card heading="After you choose a role">
          <.consequences rows={[
            {:done, "Cympho asks for approval first if your company requires it."}
          ]} />
          <.ink_foot verb="hire">
            <:primary>
              <.primary_pill navigate="/agents/new">Hire</.primary_pill>
            </:primary>
          </.ink_foot>
        </.ink_card>
      </:resolution>
    </.next_step>
    """
  end
end
