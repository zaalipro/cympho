defmodule CymphoWeb.TeamRailLive do
  @moduledoc """
  The rail's live team list ("Your team" with "N for you" chips) and the
  spending slot under it.

  Rendered from the root layout with `live_render/3`, so it is its own root
  LiveView: live navigation replaces only the main view and this one stays,
  like a sticky view. It refreshes (debounced) on agent, owner-attention, run
  and company messages for the current company.
  """
  use CymphoWeb, :live_view

  alias Cympho.Agents
  alias Cympho.OwnerAttention
  alias CymphoWeb.Events
  alias CymphoWeb.TeamRail

  on_mount {CymphoWeb.UserAuth, :team_rail}

  @refresh_ms 300

  @doc """
  The conn to render this view from the root layout with.

  Inside a router LiveView, a root-layout `live_render/3` would inherit that
  live_session's on_mount hooks on the dead render (`Phoenix.LiveView.Static`
  reads them from `conn.private`), and CompanyRBAC's `handle_params` hook
  cannot attach to a view that is not mounted at the router. The connected
  mount never sees those hooks, so both mounts run only this view's own hook.
  """
  def layout_conn(%Plug.Conn{} = conn) do
    %{conn | private: Map.delete(conn.private, :phoenix_live_view)}
  end

  @impl true
  def mount(_params, _session, socket) do
    socket = assign(socket, rows: [], spend: nil, refresh: nil)

    case socket.assigns[:current_company] do
      %{id: company_id} when is_binary(company_id) ->
        if connected?(socket) do
          Agents.subscribe(company_id)
          OwnerAttention.subscribe(company_id)
          Events.subscribe_to_runs(company_id)
          Phoenix.PubSub.subscribe(Cympho.PubSub, "company:#{company_id}:company")
        end

        {:ok, load(socket), layout: false}

      _ ->
        {:ok, socket, layout: false}
    end
  end

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, socket |> assign(:refresh, nil) |> load()}

  # Every subscribed message means the team, its items or its spend may have changed.
  def handle_info(_message, %{assigns: %{refresh: nil}} = socket) do
    {:noreply, assign(socket, :refresh, Process.send_after(self(), :refresh, @refresh_ms))}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp load(%{assigns: %{current_company: %{id: company_id}}} = socket) do
    socket
    |> assign(:rows, TeamRail.rows(company_id, socket.assigns.current_user))
    |> assign(:spend, TeamRail.spend(company_id))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section
      :if={@current_company}
      id="team-rail-list"
      class="team"
      aria-label="Your team"
      phx-hook="TeamRailToggle"
    >
      <button type="button" class="team-h" aria-expanded="true" aria-controls="team-roster">
        <span>Your team</span> <.r3_icon name="i-chev-down" class="ico s14" />
      </button>
      <ul id="team-roster" class="roster">
        <.team_row
          :for={row <- @rows}
          name={row.name}
          href={row.href}
          kind={row.kind}
          word={row.word}
          for_you={row.for_you}
          pin={row.pin}
        />
      </ul>
      <.link class="see-all" navigate={~p"/agents"}>See all</.link>
    </section>
    <.link :if={@spend} class="spend" navigate={~p"/costs"}>
      <span class="spend-e">Spending<span aria-hidden="true"> · </span>30 days</span>
      <span class="spend-v">
        <b class={@spend.paused? && "st"}>{money(@spend.spent)}</b> of {money(@spend.limit)}
      </span>
      <.tick_meter percent={@spend.percent} class={@spend.paused? && "full"}>
        <:legend></:legend>
      </.tick_meter>
      <span :if={!@spend.paused?} class="spend-l">Agents stop at {money(@spend.limit)}</span>
      <span :if={@spend.paused?} class="spend-l stop">
        Paused<span aria-hidden="true"> · </span>limit reached
      </span>
      <span :if={@spend.paused?} class="spend-go">
        Open Spending<.r3_icon name="i-arrow-right" />
      </span>
    </.link>
    """
  end

  # "$246", "$246.40"
  defp money(%Decimal{} = amount) do
    rounded = Decimal.round(amount, 2)

    if Decimal.equal?(rounded, Decimal.round(rounded, 0)),
      do: "$#{rounded |> Decimal.round(0) |> Decimal.to_string(:normal)}",
      else: "$#{Decimal.to_string(rounded, :normal)}"
  end
end
