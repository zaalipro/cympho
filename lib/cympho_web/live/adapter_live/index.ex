defmodule CymphoWeb.AdapterLive.Index do
  use CymphoWeb, :live_view

  alias Cympho.Adapters
  alias Cympho.Agents
  alias Cympho.Secrets

  @impl true
  def mount(_params, _session, socket) do
    adapters = Adapters.list_adapters()

    agents_by_adapter =
      case socket.assigns[:current_company] do
        %{id: company_id} ->
          Agents.adapter_options()
          |> Enum.into(%{}, fn key ->
            {key, Agents.list_agents_by_adapter(key, company_id)}
          end)

        _ ->
          %{}
      end

    company_id =
      case socket.assigns[:current_company] do
        %{id: id} -> id
        _ -> nil
      end

    health = overlay_company_health(Adapters.check_all_health(), company_id)

    socket =
      socket
      |> assign(:page_title, "Adapters")
      |> assign(:adapters, adapters)
      |> assign(:health, health)
      |> assign(:agents_by_adapter, agents_by_adapter)
      |> assign(:runtime_readiness, build_runtime_readiness(adapters, health, agents_by_adapter))
      |> assign(:adapter_event_error, nil)

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("refresh_health", _params, socket) do
    company_id =
      case socket.assigns[:current_company] do
        %{id: id} -> id
        _ -> nil
      end

    health = overlay_company_health(Adapters.check_all_health(), company_id)

    {:noreply,
     socket
     |> assign(:health, health)
     |> assign(:adapter_event_error, nil)
     |> assign(
       :runtime_readiness,
       build_runtime_readiness(socket.assigns.adapters, health, socket.assigns.agents_by_adapter)
     )}
  end

  @impl true
  def handle_event("test_adapter", %{"key" => key}, socket) do
    case parse_adapter_key(socket, key) do
      {:ok, key_atom} ->
        result =
          Adapters.check_health(
            key_atom,
            company_adapter_health_config(key_atom, socket.assigns[:current_company])
          )

        health = Map.put(socket.assigns.health, key_atom, result)

        message =
          case result.status do
            :healthy -> "#{adapter_name(socket, key_atom)} health check passed"
            :degraded -> "#{adapter_name(socket, key_atom)} is degraded: #{result.message}"
            :unhealthy -> "#{adapter_name(socket, key_atom)} is unhealthy: #{result.message}"
            :unknown -> "#{adapter_name(socket, key_atom)} status unknown"
          end

        {:noreply,
         socket
         |> assign(:health, health)
         |> assign(:adapter_event_error, nil)
         |> assign(
           :runtime_readiness,
           build_runtime_readiness(
             socket.assigns.adapters,
             health,
             socket.assigns.agents_by_adapter
           )
         )
         |> put_flash(:info, message)}

      :error ->
        {:noreply, assign(socket, :adapter_event_error, "Unknown adapter")}
    end
  end

  defp overlay_company_health(health, company_id) when is_binary(company_id) do
    Map.put(
      health,
      :openai_chat,
      Adapters.check_health(
        :openai_chat,
        company_adapter_health_config(:openai_chat, %{id: company_id})
      )
    )
  end

  defp overlay_company_health(health, _company_id), do: health

  defp company_adapter_health_config(:openai_chat, %{id: company_id}) do
    %{
      endpoint: company_setting_value(company_id, "OPENAI_CHAT_ENDPOINT"),
      model: company_setting_value(company_id, "OPENAI_CHAT_MODEL"),
      api_key: company_setting_value(company_id, "LLMOTIONS_API_KEY")
    }
  end

  defp company_adapter_health_config(_key, _company), do: %{}

  defp company_setting_value(company_id, key) do
    case Secrets.get_secret_by_key(company_id, key, scope: "company") do
      {:ok, secret} ->
        case Secrets.get_secret_value(secret.id) do
          {:ok, value} -> value
          _ -> nil
        end

      {:error, :not_found} ->
        nil
    end
  end

  defp parse_adapter_key(socket, key) do
    key = to_string(key)

    socket.assigns.adapters
    |> Enum.find(fn adapter -> Atom.to_string(adapter.key) == key end)
    |> case do
      nil -> :error
      adapter -> {:ok, adapter.key}
    end
  end

  defp build_runtime_readiness(adapters, health, agents_by_adapter) do
    counts = adapter_counts(adapters, health, agents_by_adapter)
    attention_adapter = first_attention_adapter(adapters, health, agents_by_adapter)

    %{
      summary: runtime_summary(counts, attention_adapter),
      tone: runtime_tone(counts),
      stats: runtime_stats(counts),
      attention_adapter: attention_adapter,
      actions: runtime_actions(counts)
    }
  end

  defp adapter_counts(adapters, health, agents_by_adapter) do
    healthy = Enum.count(adapters, &(health_status(health, &1.key) == :healthy))
    unavailable = Enum.count(adapters, &(not &1.available))
    assigned = agents_by_adapter |> Map.values() |> Enum.map(&length/1) |> Enum.sum()
    attention = Enum.count(adapters, &adapter_attention?(&1, health))

    configured =
      Enum.count(adapters, fn adapter ->
        length(Map.get(agents_by_adapter, adapter.key, [])) > 0
      end)

    %{
      total: length(adapters),
      healthy: healthy,
      unavailable: unavailable,
      assigned_agents: assigned,
      configured_adapters: configured,
      attention: attention
    }
  end

  defp health_status(health, key), do: Map.get(Map.get(health, key, %{}), :status, :unknown)

  defp first_attention_adapter(adapters, health, agents_by_adapter) do
    adapters
    |> Enum.filter(&adapter_attention?(&1, health))
    |> Enum.filter(fn adapter ->
      length(Map.get(agents_by_adapter, adapter.key, [])) > 0
    end)
    |> Enum.sort_by(& &1.name)
    |> List.first()
  end

  defp adapter_attention?(adapter, health) do
    health_status(health, adapter.key) in [:degraded, :unhealthy, :unknown] or
      not adapter.available
  end

  defp runtime_summary(%{total: 0}, _attention_adapter), do: "No adapters are registered."

  defp runtime_summary(%{assigned_agents: 0} = counts, _attention_adapter) do
    "#{counts.healthy} of #{counts.total} #{adapter_noun(counts.total)} healthy, but no agents are assigned to a runtime yet."
  end

  defp runtime_summary(%{attention: 0} = counts, _attention_adapter) do
    "#{counts.healthy} of #{counts.total} #{adapter_noun(counts.total)} healthy with #{counts.assigned_agents} assigned #{pluralize(counts.assigned_agents, "agent")}."
  end

  defp runtime_summary(%{assigned_agents: assigned} = counts, nil) when assigned > 0 do
    "#{counts.healthy} of #{counts.total} #{adapter_noun(counts.total)} healthy; assigned runtimes are ready."
  end

  defp runtime_summary(counts, nil) do
    "#{counts.healthy} of #{counts.total} #{adapter_noun(counts.total)} healthy; #{counts.attention} runtime signals need attention."
  end

  defp runtime_summary(counts, adapter) do
    "#{counts.healthy} of #{counts.total} #{adapter_noun(counts.total)} healthy; check #{adapter.name} before routing more work."
  end

  # "1 adapter is healthy", not "1 adapters are healthy".
  defp adapter_noun(1), do: "adapter is"
  defp adapter_noun(_n), do: "adapters are"

  defp runtime_tone(%{total: 0}), do: :blocked
  defp runtime_tone(%{assigned_agents: 0}), do: :attention
  defp runtime_tone(%{healthy: healthy}) when healthy == 0, do: :blocked
  defp runtime_tone(%{attention: 0}), do: :ready
  defp runtime_tone(_counts), do: :attention

  defp runtime_stats(counts) do
    [
      %{label: "Healthy", value: counts.healthy, note: "#{counts.total} registered"},
      %{
        label: "Assigned agents",
        value: counts.assigned_agents,
        note: "#{counts.configured_adapters} #{adapter_noun(counts.configured_adapters)} in use"
      },
      %{
        label: "Needs attention",
        value: counts.attention,
        note: "#{counts.unavailable} unavailable"
      }
    ]
  end

  defp runtime_actions(%{assigned_agents: 0}) do
    [
      %{label: "Add agent", url: ~p"/agents/new", tone: :primary, icon: "hero-plus-mini"},
      %{label: "Secrets", url: ~p"/settings/secrets", tone: :neutral, icon: "hero-key-mini"},
      %{label: "Operations", url: ~p"/operations", tone: :neutral, icon: "hero-command-line-mini"}
    ]
  end

  defp runtime_actions(_counts) do
    [
      %{
        label: "Operations",
        url: ~p"/operations",
        tone: :primary,
        icon: "hero-command-line-mini"
      },
      %{label: "Add agent", url: ~p"/agents/new", tone: :neutral, icon: "hero-plus-mini"},
      %{label: "Secrets", url: ~p"/settings/secrets", tone: :neutral, icon: "hero-key-mini"}
    ]
  end

  defp adapter_name(socket, key) do
    case Enum.find(socket.assigns.adapters, fn a -> a.key == key end) do
      nil -> Atom.to_string(key)
      adapter -> adapter.name
    end
  end

  # One health vocabulary per card: an adapter that is not installed reads
  # "Unavailable" instead of contradicting a probe status of "Degraded".
  defp card_health_status(%{available: false}, _health), do: :unavailable
  defp card_health_status(_adapter, health), do: Map.get(health, :status, :unknown)

  defp health_status_class(:healthy), do: "bg-success/20 text-success"
  defp health_status_class(:degraded), do: "bg-amber-500/20 text-amber-400"
  defp health_status_class(:unhealthy), do: "bg-brand/20 text-brand"
  defp health_status_class(:unavailable), do: "bg-brand/20 text-brand"
  defp health_status_class(_), do: "bg-text-quaternary/20 text-text-quaternary"

  defp health_dot_class(:healthy), do: "bg-success animate-pulse"
  defp health_dot_class(:degraded), do: "bg-amber-400 animate-pulse"
  defp health_dot_class(:unhealthy), do: "bg-brand animate-pulse"
  defp health_dot_class(:unavailable), do: "bg-brand"
  defp health_dot_class(_), do: "bg-text-quaternary"

  defp health_status_label(:healthy), do: "Healthy"
  defp health_status_label(:degraded), do: "Degraded"
  defp health_status_label(:unhealthy), do: "Unhealthy"
  defp health_status_label(:unavailable), do: "Unavailable"
  defp health_status_label(_), do: "Unknown"

  defp runtime_panel_class(:ready), do: "border-success/25 bg-success/10"
  defp runtime_panel_class(:attention), do: "border-amber-500/25 bg-amber-500/10"
  defp runtime_panel_class(:blocked), do: "border-brand/25 bg-brand/10"
  defp runtime_panel_class(_tone), do: "border-border bg-surface"

  defp runtime_action_class(:primary) do
    "inline-flex h-9 items-center justify-center gap-2 rounded-lg bg-brand px-3 text-sm font-510 text-on-primary transition-colors hover:bg-accent-hover"
  end

  defp runtime_action_class(_tone) do
    "inline-flex h-9 items-center justify-center gap-2 rounded-lg border border-border bg-surface px-3 text-sm font-510 text-text-secondary transition-colors hover:bg-surface-hover hover:text-text-primary"
  end

  defp pluralize(1, word), do: word
  defp pluralize(_count, word), do: word <> "s"

  defp adapter_icon(:claude_code), do: "⚡"
  defp adapter_icon(:codex), do: "🔬"
  defp adapter_icon(:cursor), do: "🖱"
  defp adapter_icon(:http), do: "🌐"
  defp adapter_icon(:openai_chat), do: "💬"
  defp adapter_icon(:openclaw), do: "🐾"
  defp adapter_icon(:process), do: "⚙"
  defp adapter_icon(_), do: "📦"

  defp agent_count(assigns, key) do
    length(Map.get(assigns.agents_by_adapter, key, []))
  end
end
