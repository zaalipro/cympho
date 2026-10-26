defmodule CymphoWeb.MultiCompanyOverviewLive.Index do
  use CymphoWeb, :live_view

  alias Cympho.MultiCompanyOverview

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:page_title, "Compare companies") |> refresh()}
  end

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, refresh(socket)}

  defp refresh(socket) do
    assign(socket, :summaries, MultiCompanyOverview.list_for_user(socket.assigns.current_user.id))
  end

  defp workflow_path(company_id, destination) do
    ~p"/switch-company/#{company_id}?#{[return_to: destination]}"
  end

  defp money(amount), do: "$" <> (amount |> Decimal.round(2) |> Decimal.to_string(:normal))

  # A comparable limit's state as a word and its shape (v7 §1.5); below the
  # warning share it is just the share, in mono (nil here).
  defp budget_status(%{budget_status: :over_budget}), do: {:stopped, "Limit reached"}
  defp budget_status(%{budget_status: :watch}), do: {:waiting, "Near the limit"}
  defp budget_status(_budget), do: nil

  @impl true
  def render(assigns) do
    ~H"""
    <.page_frame page="overview" title="Compare companies" data-ui-complex-page>
      <:header_end>
        <.pill id="refresh-overview" phx-click="refresh">Refresh</.pill>
      </:header_end>

      <p class="gl-sub ov-note">
        A read-only snapshot of the companies you can access; running counts leave out queued runs.
      </p>

      <.band_card :if={@summaries == []} id="overview-empty-t" title="Companies">
        <.quiet_empty title="No accessible companies." />
      </.band_card>

      <.band_card
        :for={summary <- @summaries}
        id={"overview-company-#{summary.company.id}-t"}
        section_id={"overview-company-#{summary.company.id}"}
        aria-label={summary.company.name}
        title={summary.company.name}
      >
        <:header_end>
          <span :if={budget_status(summary.budget)} class="ov-st">
            <.status_word
              kind={elem(budget_status(summary.budget), 0)}
              word={elem(budget_status(summary.budget), 1)}
            />
          </span>
          <span
            :if={!budget_status(summary.budget) and summary.budget.budget_comparable}
            class="meta mono"
          >
            {summary.budget.budget_used_percent}% used
          </span>
          <span :if={!summary.budget.budget_comparable} class="tag">
            {summary.budget.budget_status_label}
          </span>
        </:header_end>
        <div class="strip ov-strip">
          <div class="cell">
            <span class="v mono" data-summary="running">{summary.running}</span><span class="l">Running now</span>
          </div>
          <div class="cell">
            <span class="v mono" data-summary="review">{summary.review}</span><span class="l">Tasks in review</span>
          </div>
          <div class="cell">
            <span class="v mono" data-summary="blocked">{summary.blocked}</span><span class="l">Blocked tasks</span>
          </div>
        </div>
        <div class="lim ov-lim">
          <p class="lim-line">
            Tracked {summary.budget.budget_period} spend
            <b class="mono">{money(summary.budget.budget_spend)}</b><span :if={
              summary.budget.budget_comparable
            }>
              of <span class="mono">{money(summary.budget.budget_limit)}</span><span aria-hidden="true"> · </span><span class="mono">{money(summary.budget.budget_remaining)}</span> left
            </span>
          </p>
          <p :if={!summary.budget.budget_comparable} class="help">
            No company-wide balance.
            <span :if={summary.budget.budget_configured}>
              Scoped controls are not a comparable company limit.
            </span>
            <span :if={!summary.budget.budget_configured}>No budget configured.</span>
          </p>
          <p :if={summary.has_unpriced_usage?} class="help">
            Some usage is unpriced; tracked spend may be incomplete.
          </p>
        </div>
        <nav class="ov-links" aria-label={"#{summary.company.name} workflows"}>
          <.text_link href={workflow_path(summary.company.id, "/dashboard")} arrow={false}>
            Home
          </.text_link>
          <.text_link href={workflow_path(summary.company.id, "/issues")} arrow={false}>
            Tasks
          </.text_link>
          <span class="ui-advanced-only">
            <.text_link href={workflow_path(summary.company.id, "/reviews")} arrow={false}>
              Reviews
            </.text_link>
          </span>
          <.text_link href={workflow_path(summary.company.id, "/projects")} arrow={false}>
            Projects
          </.text_link>
          <.text_link href={workflow_path(summary.company.id, "/costs")} arrow={false}>
            Spending
          </.text_link>
        </nav>
      </.band_card>
    </.page_frame>
    """
  end
end
