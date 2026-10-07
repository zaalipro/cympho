defmodule CymphoWeb.MultiCompanyOverviewLive.Index do
  use CymphoWeb, :live_view

  alias Cympho.MultiCompanyOverview

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:page_title, "Company overview") |> refresh()}
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

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-5xl mx-auto p-6 space-y-6">
      <header class="flex items-start justify-between gap-4">
        <div>
          <h1 class="text-xl font-semibold text-text-primary">Company overview</h1>
          <p class="mt-2 text-sm text-text-secondary">
            Read-only snapshot of companies you can access. Your home stays unchanged.
          </p>
        </div>
        <button id="refresh-overview" phx-click="refresh" class="btn-secondary">Refresh</button>
      </header>
      <p class="text-xs text-text-tertiary">
        Running executions exclude queued and pending runs. Refresh to update counts and access.
      </p>
      <p :if={@summaries == []} class="text-sm text-text-secondary">No accessible companies.</p>
      <section
        :for={summary <- @summaries}
        id={"overview-company-#{summary.company.id}"}
        aria-label={summary.company.name}
        class="rounded-xl border border-border bg-panel p-5 space-y-4"
      >
        <h2 class="text-lg font-semibold text-text-primary">
          <a href={workflow_path(summary.company.id, "/dashboard")} class="hover:underline">
            {summary.company.name}
          </a>
        </h2>
        <dl class="grid grid-cols-3 gap-4 text-sm">
          <div>
            <dt class="text-text-secondary">Running executions</dt>
            <dd data-summary="running" class="mt-1 text-xl tabular-nums">{summary.running}</dd>
          </div>
          <div>
            <dt class="text-text-secondary">Issues in review</dt>
            <dd data-summary="review" class="mt-1 text-xl tabular-nums">{summary.review}</dd>
          </div>
          <div>
            <dt class="text-text-secondary">Blocked issues</dt>
            <dd data-summary="blocked" class="mt-1 text-xl tabular-nums">{summary.blocked}</dd>
          </div>
        </dl>
        <div class="text-sm space-y-1">
          <p class="font-medium">Budget: {summary.budget.budget_status_label}</p>
          <p class="text-text-secondary">
            Tracked {summary.budget.budget_period} spend: {money(summary.budget.budget_spend)}
          </p>
          <p :if={summary.budget.budget_comparable} class="text-text-secondary">
            Company limit: {money(summary.budget.budget_limit)} · Remaining: {money(
              summary.budget.budget_remaining
            )}
          </p>
          <p :if={!summary.budget.budget_comparable} class="text-text-secondary">
            No company-wide balance.
            <span :if={summary.budget.budget_configured}>
              Scoped controls are not a comparable company limit.
            </span>
            <span :if={!summary.budget.budget_configured}>No budget configured.</span>
          </p>
          <p :if={summary.has_unpriced_usage?} class="text-text-tertiary">
            Some usage is unpriced; tracked spend may be incomplete.
          </p>
        </div>
        <nav
          class="flex flex-wrap gap-4 text-sm text-text-secondary"
          aria-label={"#{summary.company.name} workflows"}
        >
          <a href={workflow_path(summary.company.id, "/issues")} class="hover:text-text-primary">
            Tasks
          </a>
          <a href={workflow_path(summary.company.id, "/reviews")} class="hover:text-text-primary">
            Reviews
          </a>
          <a href={workflow_path(summary.company.id, "/projects")} class="hover:text-text-primary">
            Projects
          </a>
          <a href={workflow_path(summary.company.id, "/costs")} class="hover:text-text-primary">
            Costs
          </a>
        </nav>
      </section>
    </div>
    """
  end
end
