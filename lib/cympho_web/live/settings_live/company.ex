defmodule CymphoWeb.SettingsLive.Company do
  @moduledoc """
  Settings › Company (r3 P8): where Settings opens. The Next step is the
  owner's alerts (B6: "Tell me when…", saved on the email channel the
  dispatcher reads), then the section nav beside Details and Power. Members
  and Billing are sections of this page (`?section=`).

  Power uses the existing runtime-control POST forms (CSRF, role check,
  audit), so this view adds no company-mutating event of its own; the one
  event, `choose_alerts`, changes only the signed-in user's preferences.
  """
  use CymphoWeb, :live_view

  import CymphoWeb.Format, only: [money: 1, window: 1]

  alias Cympho.{Adapters, Agents, Companies, Finances, Goals, Users}
  alias Cympho.Finances.Pricing
  alias Cympho.Notifications.Dispatcher
  alias CymphoWeb.NextStep
  alias CymphoWeb.SettingsLive
  alias CymphoWeb.TeamRail

  @sections ~w(details members billing)

  @impl true
  def mount(_params, _session, socket) do
    %{id: company_id} = socket.assigns.current_company
    {:ok, user} = Users.get_user(socket.assigns.current_user.id)
    company = Companies.get_company!(company_id)

    {:ok,
     socket
     |> assign(:page_title, "Settings")
     |> assign(:company, company)
     |> assign(:user, user)
     |> assign(:prefs, Users.ensure_default_prefs(user.id))
     |> assign(:goal, first_active_goal(company_id))
     |> assign(:spending, TeamRail.spending(company_id))
     |> assign(:board_member?, Companies.is_board_member?(user.id, company_id))}
  end

  @impl true
  def handle_params(params, _url, socket) do
    section = if params["section"] in @sections, do: params["section"], else: "details"

    {:noreply,
     socket
     |> assign(:section, String.to_existing_atom(section))
     |> assign(:picked?, Map.has_key?(params, "section"))
     |> assign_section(section)}
  end

  @impl true
  def handle_event("choose_alerts", params, socket) do
    chosen = List.wrap(params["events"])
    user = socket.assigns.user
    email = Enum.find(socket.assigns.prefs, &(&1.channel_type == "email"))
    events = Map.new(SettingsLive.Index.alert_events(), fn {key, _} -> {key, key in chosen} end)
    saved = Map.merge((email.config || %{})["events"] || %{}, events)

    with {:ok, _} <- Users.update_pref_events(email.id, saved),
         {:ok, _} <- maybe_enable_email(user.id, email, events) do
      {:noreply,
       socket
       |> assign(:prefs, Users.list_notification_prefs(user.id))
       |> push_event("toast", %{message: "Alerts saved.", type: "success"})}
    else
      _ ->
        {:noreply,
         push_event(socket, "toast", %{message: "Could not save alerts.", type: "error"})}
    end
  end

  # The effect sentence promises email: choosing an event turns email on if it was off.
  defp maybe_enable_email(user_id, %{enabled: false}, events) do
    if Enum.any?(events, fn {_key, on?} -> on? end),
      do: Users.upsert_notification_pref(user_id, "email", %{enabled: true}),
      else: {:ok, :unchanged}
  end

  defp maybe_enable_email(_user_id, _email, _events), do: {:ok, :unchanged}

  defp assign_section(socket, "members") do
    company_id = socket.assigns.company.id

    socket
    |> assign(:members, Companies.list_memberships(company_id))
    |> assign(:pending_invites, Companies.list_pending_invites(company_id))
  end

  defp assign_section(socket, "billing") do
    company_id = socket.assigns.company.id

    policies =
      Finances.list_budget_policies(company_id, scope: "company", is_active: true)

    socket
    |> assign(:stops_at_limit?, Enum.any?(policies, &(&1.action_on_exceed == "block")))
    |> assign(:price_rows, price_rows(company_id))
  end

  defp assign_section(socket, _details), do: socket

  defp first_active_goal(company_id) do
    company_id |> Goals.list_goals_by_company() |> Enum.find(&(&1.status == "active"))
  end

  ## ── Alerts ────────────────────────────────────────────────────

  # Chosen once the email channel carries an explicit choice for any of the four
  # events added with the chooser (the chooser and the Alerts matrix both save one).
  defp alerts_chosen?(prefs) do
    case Enum.find(prefs, &(&1.channel_type == "email")) do
      %{config: %{"events" => %{} = events}} ->
        Enum.any?(
          ~w(agent_question review_ready work_stopped spend_threshold),
          &Map.has_key?(events, &1)
        )

      _ ->
        false
    end
  end

  defp channel(prefs, type) do
    pref = Enum.find(prefs, &(&1.channel_type == type))
    on? = pref != nil and pref.enabled

    %{
      label: String.capitalize(type),
      on?: on?,
      dots:
        for(
          {key, _} <- SettingsLive.Index.alert_events(),
          do: on? and Dispatcher.event_allowed?(pref, key)
        )
    }
  end

  defp channels(prefs), do: Enum.map(~w(email telegram webhook), &channel(prefs, &1))

  defp alerts_sentence(prefs) do
    sent =
      for %{enabled: true} = pref <- prefs,
          {key, _} <- SettingsLive.Index.alert_events(),
          Dispatcher.event_allowed?(pref, key),
          do: {pref.channel_type, key}

    case sent do
      [] ->
        "Today Cympho sends you no alerts."

      [{"email", "human_approval_required"}] ->
        "Today Cympho only emails you when an approval is needed."

      _ ->
        "Today Cympho alerts you about #{sent |> Enum.uniq_by(&elem(&1, 1)) |> length()} of 5 events."
    end
  end

  attr :channels, :list, required: true

  # "Where alerts go" (011's matrix in miniature): one dot per event, numbered like the chooser's rows.
  defp coverage(assigns) do
    ~H"""
    <div class="cov">
      <p class="cov-k">
        <span class="cov-l">Where alerts go</span><span class="cov-n mono" aria-hidden="true"><span :for={
          n <- 1..5
        }>{n}</span></span>
      </p>
      <ul>
        <li :for={c <- @channels}>
          <span class="cov-c">{c.label}</span>
          <span class="cov-s">
            <.status_glyph kind={if c.on?, do: :done, else: :idle} big />{if c.on?,
              do: "On",
              else: "Off"}
          </span>
          <span class="cov-d" aria-hidden="true">
            <i :for={dot <- c.dots} class={dot && "y"}></i>
          </span>
        </li>
      </ul>
    </div>
    <div class="pf">
      <span class="pf-m">
        <%= for {c, n} <- Enum.with_index(@channels) do %>
          <span :if={n > 0} aria-hidden="true"> · </span>{c.label} {if c.on?, do: "on", else: "off"}
        <% end %>
      </span>
      <.link class="ul" navigate="/settings/notifications">Open Alerts</.link>
    </div>
    """
  end

  ## ── Power ─────────────────────────────────────────────────────

  defp power_key(company) do
    case power_word(company) do
      "Paused" -> "paused"
      "Low power" -> "low"
      _ -> "full"
    end
  end

  defp power_word(%{status: "paused"}), do: "Paused"
  defp power_word(%{governance_config: %{"runtime_mode" => "low_power"}}), do: "Low power"
  defp power_word(_company), do: "Full power"

  # The switch's runtime actions and confirm texts (CompanyRail.runtime_control_menu/1).
  defp power_rows(company) do
    paused? = company.status == "paused"
    low? = match?(%{"runtime_mode" => "low_power"}, company.governance_config)

    [
      !paused? && !low? &&
        %{
          icon: "i-low",
          title: "Low power",
          detail: "Only High and Critical tasks run.",
          action: "/runtime-control/low-power",
          button: "Switch to Low power",
          tone: nil,
          confirm: "Switch to low power? Only urgent work keeps running."
        },
      !paused? && low? &&
        %{
          icon: "i-low",
          title: "Full power",
          detail: "Every task can run again.",
          action: "/runtime-control/resume",
          button: "Switch to Full power",
          tone: nil,
          confirm: nil
        },
      !paused? &&
        %{
          icon: "i-pause",
          title: "Pause company",
          detail: "Queued work is saved for later.",
          action: "/runtime-control/pause",
          button: "Pause company",
          tone: "warn",
          confirm: "Pause your agents? Queued work is saved for later."
        },
      paused? &&
        %{
          icon: "i-pause",
          title: "Resume agents",
          detail: "Agents start picking up work again.",
          action: "/runtime-control/resume",
          button: "Resume agents",
          tone: nil,
          confirm: nil
        },
      %{
        icon: "i-halt",
        title: "Stop company",
        detail: "Agents stop and the queue is cleared.",
        action: "/runtime-control/stop",
        button: "Stop company",
        tone: "stop",
        confirm: "Stop your agents and clear the queue?"
      }
    ]
    |> Enum.filter(& &1)
  end

  ## ── Billing ───────────────────────────────────────────────────

  # One row per runtime and price: what the spending limit can count.
  defp price_rows(company_id) do
    company_id
    |> Agents.list_agents_by_company()
    |> Enum.reject(&(&1.governance_status == "terminated"))
    |> Enum.group_by(&{runtime_label(&1.adapter), price_text(&1)}, & &1.name)
    |> Enum.map(fn {{runtime, price}, names} ->
      %{runtime: runtime, price: price, names: names |> Enum.sort() |> Enum.join(", ")}
    end)
    |> Enum.sort_by(& &1.runtime)
  end

  defp price_text(agent) do
    config = Map.merge(agent.config || %{}, agent.runtime_config || %{})

    pricing =
      Map.merge(
        (agent.config || %{})["pricing"] || %{},
        (agent.runtime_config || %{})["pricing"] || %{}
      )

    cond do
      config["billing_mode"] == "flat_rate" ->
        "Flat rate: runs count as $0"

      map_size(pricing) > 0 ->
        Enum.map_join(pricing, "; ", fn {model, rates} ->
          "#{model} · $#{rates["input_usd_per_mtok"]} in · $#{rates["output_usd_per_mtok"]} out per 1M tokens"
        end)

      reports_cost?(agent.adapter, config) ->
        "Reports its own cost"

      true ->
        "No prices set"
    end
  end

  defp reports_cost?(adapter, config) do
    case adapter && Adapters.lookup(adapter) do
      {:ok, module} -> Pricing.usage_reporting(module, config) == :cost
      _ -> false
    end
  end

  defp runtime_label(:claude_code), do: "Claude Code"
  defp runtime_label(:codex), do: "Codex"
  defp runtime_label(:openai_chat), do: "OpenAI-compatible chat"
  defp runtime_label(:http), do: "Custom HTTP"
  defp runtime_label(nil), do: "Default runtime"

  defp runtime_label(adapter),
    do: adapter |> to_string() |> String.replace("_", " ") |> String.capitalize()

  ## ── Formatting ────────────────────────────────────────────────

  defp role_word(role), do: role |> to_string() |> String.capitalize()

  defp initials(nil), do: "?"

  defp initials(name),
    do:
      name
      |> String.split()
      |> Enum.map_join(&String.first/1)
      |> String.slice(0, 2)
      |> String.upcase()
end
