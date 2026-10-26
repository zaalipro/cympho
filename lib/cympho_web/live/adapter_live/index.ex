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
      |> assign(:page_title, "How agents run")
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

  # Health (/operations) is an Advanced-only page, so its link is Advanced-only too.
  defp runtime_actions(%{assigned_agents: 0}) do
    [
      %{label: "Add agent", url: ~p"/agents/new"},
      %{label: "Keys and secrets", url: ~p"/settings/secrets"},
      %{label: "Health", url: ~p"/operations", advanced?: true}
    ]
  end

  defp runtime_actions(_counts) do
    [
      %{label: "Health", url: ~p"/operations", advanced?: true},
      %{label: "Add agent", url: ~p"/agents/new"},
      %{label: "Keys and secrets", url: ~p"/settings/secrets"}
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

  # Health as a word plus a shape (v7 §1.5).
  defp health_status(:healthy), do: {:done, "Ready"}
  defp health_status(:degraded), do: {:waiting, "Degraded"}
  defp health_status(:unhealthy), do: {:stopped, "Unhealthy"}
  defp health_status(:unavailable), do: {:stopped, "Unavailable"}
  defp health_status(_), do: {:idle, "Not checked"}

  defp health_message(health, key), do: health |> Map.get(key, %{}) |> Map.get(:message)

  defp agents_label([]), do: "No agents"
  defp agents_label(agents) when length(agents) <= 3, do: Enum.map_join(agents, ", ", & &1.name)
  defp agents_label(agents), do: "#{length(agents)} agents"

  defp pluralize(1, word), do: word
  defp pluralize(_count, word), do: word <> "s"
end
