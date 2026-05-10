defmodule CymphoWeb.AgentLive.Remote do
  use CymphoWeb, :live_view

  alias Cympho.Agents
  alias Cympho.Agrenting

  @default_role "engineer"

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Hire Remote Agent")
      |> assign(:query, "")
      |> assign(:capability, "")
      |> assign(:remote_agents, [])
      |> assign(:all_agents, [])
      |> assign(:capability_options, [])
      |> assign(:hired_remote_dids, MapSet.new())
      |> assign(:loading?, connected?(socket))
      |> assign(:integration_status, :checking)
      |> assign(:error_message, nil)

    if connected?(socket), do: send(self(), :load_agents)

    {:ok, socket}
  end

  @impl true
  def handle_info(:load_agents, socket) do
    {:noreply, load_agents(socket)}
  end

  @impl true
  def handle_event("search", %{"filters" => filters}, socket) do
    socket =
      socket
      |> assign(:query, String.trim(filters["query"] || ""))
      |> assign(:capability, filters["capability"] || "")
      |> assign(:loading?, true)

    {:noreply, load_agents(socket)}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, socket |> assign(:loading?, true) |> load_agents()}
  end

  def handle_event("hire_agent", params, socket) do
    company_id = current_company_id(socket)
    did = params["agent_did"]

    with {:ok, remote_agent} <- find_remote_agent(socket.assigns.all_agents, did),
         :ok <- ensure_not_already_hired(company_id, did),
         attrs <- proxy_agent_attrs(socket, remote_agent, params),
         {:ok, agent} <- Agents.create_agent(attrs) do
      {:noreply,
       socket
       |> put_flash(:info, "#{agent.name} is now available in Cympho.")
       |> push_navigate(to: ~p"/agents/#{agent.id}?tab=configuration")}
    else
      {:error, :already_hired, agent} ->
        {:noreply,
         socket
         |> put_flash(:info, "That Agrenting agent is already connected.")
         |> push_navigate(to: ~p"/agents/#{agent.id}")}

      {:error, :not_found} ->
        {:noreply,
         put_flash(socket, :error, "Remote agent was not found. Refresh and try again.")}

      {:error, :pending_board_approval, approval_id} ->
        {:noreply,
         socket
         |> put_flash(:info, "Remote agent hire requires board approval.")
         |> push_navigate(to: ~p"/board-approvals/#{approval_id}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, put_flash(socket, :error, format_changeset_errors(changeset))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not hire remote agent: #{inspect(reason)}")}
    end
  end

  defp load_agents(socket) do
    company_id = current_company_id(socket)

    cond do
      is_nil(company_id) ->
        socket
        |> assign(:loading?, false)
        |> assign(:integration_status, :missing_company)
        |> assign(:hired_remote_dids, MapSet.new())
        |> assign(:error_message, "Select a company before hiring remote agents.")

      not Agrenting.configured?(company_id) ->
        socket
        |> assign(:loading?, false)
        |> assign(:integration_status, :not_configured)
        |> assign(:remote_agents, [])
        |> assign(:all_agents, [])
        |> assign(:capability_options, [])
        |> assign(:hired_remote_dids, hired_remote_dids(company_id))
        |> assign(:error_message, nil)

      true ->
        filters =
          if socket.assigns.capability == "",
            do: %{},
            else: %{"capability" => socket.assigns.capability}

        case Agrenting.list_agents(company_id, filters) do
          {:ok, agents} ->
            agents = Enum.sort_by(agents, &agent_sort_key/1)
            hired_remote_dids = hired_remote_dids(company_id)

            socket
            |> assign(:loading?, false)
            |> assign(:integration_status, :ready)
            |> assign(:all_agents, agents)
            |> assign(:remote_agents, filter_agents(agents, socket.assigns.query))
            |> assign(:capability_options, capability_options(agents))
            |> assign(:hired_remote_dids, hired_remote_dids)
            |> assign(:error_message, nil)

          {:error, reason} ->
            socket
            |> assign(:loading?, false)
            |> assign(:integration_status, :error)
            |> assign(:remote_agents, [])
            |> assign(:hired_remote_dids, hired_remote_dids(company_id))
            |> assign(:error_message, "Agrenting request failed: #{inspect(reason)}")
        end
    end
  end

  defp proxy_agent_attrs(socket, remote_agent, params) do
    company_id = current_company_id(socket)
    capability = selected_capability(remote_agent, params["capability"])
    max_price = normalize_price(params["max_price"], remote_agent["base_price"])
    delivery_mode = if params["delivery_mode"] == "push", do: "push", else: "output"
    role = normalize_role(params["role"])
    name = remote_agent["name"] || remote_agent["did"] || "Agrenting Agent"

    base_url =
      case Agrenting.company_config(company_id) do
        {:ok, config} -> config["base_url"]
        _ -> nil
      end

    %{
      "name" => name,
      "title" => remote_title(remote_agent, capability),
      "role" => role,
      "status" => "idle",
      "adapter" => "agrenting",
      "company_id" => company_id,
      "max_concurrent_jobs" => "1",
      "config" =>
        %{
          "agent_did" => remote_agent["did"],
          "capability" => capability,
          "max_price" => max_price,
          "delivery_mode" => delivery_mode,
          "base_url" => base_url,
          "remote_profile" => remote_profile_snapshot(remote_agent)
        }
        |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
        |> Map.new(),
      "capabilities" => %{
        "source" => "agrenting",
        "remote_capabilities" => remote_agent["capabilities"] || []
      },
      "instructions" => remote_instructions(name, capability, delivery_mode)
    }
  end

  defp ensure_not_already_hired(nil, _did), do: :ok

  defp ensure_not_already_hired(company_id, did) do
    existing =
      company_id
      |> Agents.list_agents_by_company()
      |> Enum.find(fn agent ->
        agent.adapter == :agrenting and get_in(agent.config || %{}, ["agent_did"]) == did
      end)

    if existing, do: {:error, :already_hired, existing}, else: :ok
  end

  defp hired_remote_dids(nil), do: MapSet.new()

  defp hired_remote_dids(company_id) do
    company_id
    |> Agents.list_agents_by_company()
    |> Enum.filter(&(&1.adapter == :agrenting))
    |> Enum.map(&get_in(&1.config || %{}, ["agent_did"]))
    |> Enum.reject(&(&1 in [nil, ""]))
    |> MapSet.new()
  end

  defp find_remote_agent(agents, did) do
    case Enum.find(agents, &(&1["did"] == did)) do
      nil -> {:error, :not_found}
      agent -> {:ok, agent}
    end
  end

  defp filter_agents(agents, ""), do: agents

  defp filter_agents(agents, query) do
    query = String.downcase(query)

    Enum.filter(agents, fn agent ->
      [
        agent["name"],
        agent["did"],
        agent["category"],
        agent["ai_provider"],
        agent["ai_model"],
        Enum.join(agent["capabilities"] || [], " ")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")
      |> String.downcase()
      |> String.contains?(query)
    end)
  end

  defp capability_options(agents) do
    agents
    |> Enum.flat_map(&(&1["capabilities"] || []))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&{humanize(&1), &1})
    |> then(&[{"All capabilities", ""} | &1])
  end

  defp selected_capability(_remote_agent, requested) when requested not in [nil, ""] do
    requested
  end

  defp selected_capability(remote_agent, _requested) do
    remote_agent["capabilities"]
    |> List.wrap()
    |> List.first()
    |> case do
      nil -> "general"
      capability -> capability
    end
  end

  defp normalize_price(value, fallback) when value in [nil, ""], do: fallback || "0"
  defp normalize_price(value, _fallback), do: value

  defp normalize_role(role) when role in ~w(engineer product_manager designer ceo cto), do: role
  defp normalize_role(_), do: @default_role

  defp remote_title(remote_agent, capability) do
    [
      "Agrenting",
      remote_agent["category"],
      humanize(capability)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" / ")
  end

  defp remote_profile_snapshot(agent) do
    Map.take(agent, [
      "id",
      "name",
      "did",
      "capabilities",
      "pricing_model",
      "base_price",
      "reputation_score",
      "status",
      "ai_provider",
      "ai_model",
      "metadata"
    ])
  end

  defp remote_instructions(name, capability, delivery_mode) do
    """
    You represent the Agrenting remote agent #{name}.
    Default remote capability: #{capability}.
    Default delivery mode: #{delivery_mode}.

    Follow the Cympho issue prompt exactly. Return a concise final owner-facing comment and include a valid cympho-actions JSON block so Cympho can update issue state, attach work products, or link PRs.
    """
    |> String.trim()
  end

  defp agent_sort_key(agent) do
    {-decimal_float(agent["reputation_score"]), decimal_float(agent["base_price"]),
     agent["name"] || ""}
  end

  defp decimal_float(nil), do: 0.0

  defp decimal_float(value) when is_binary(value) do
    case Float.parse(value) do
      {float, _} -> float
      :error -> 0.0
    end
  end

  defp decimal_float(value) when is_number(value), do: value * 1.0
  defp decimal_float(_), do: 0.0

  defp current_company_id(socket) do
    case socket.assigns[:current_company] do
      %{id: id} -> id
      _ -> nil
    end
  end

  def role_options do
    [
      {"Engineer", "engineer"},
      {"Product Manager", "product_manager"},
      {"Designer", "designer"},
      {"CTO", "cto"},
      {"CEO", "ceo"}
    ]
  end

  def capability_select_options(agent) do
    agent["capabilities"]
    |> List.wrap()
    |> Enum.map(&{humanize(&1), &1})
    |> case do
      [] -> [{"General", "general"}]
      options -> options
    end
  end

  def delivery_options do
    [{"Output + artifacts", "output"}, {"Push to repository", "push"}]
  end

  def hired_remote_agent?(hired_dids, agent) do
    MapSet.member?(hired_dids || MapSet.new(), agent["did"])
  end

  def provider_model_label(agent) do
    [agent["ai_provider"], agent["ai_model"]]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" / ")
  end

  def humanize(value) when is_binary(value) do
    value
    |> String.replace(["_", "-"], " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  def humanize(value), do: to_string(value)

  def status_badge_class("active"), do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"
  def status_badge_class("online"), do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"
  def status_badge_class("busy"), do: "border-amber-500/25 bg-amber-500/10 text-amber-300"
  def status_badge_class(_), do: "border-border bg-surface text-text-tertiary"

  def price_label(nil), do: "No price"
  def price_label(""), do: "No price"
  def price_label(value), do: "$#{value}"

  def rating_label(nil), do: "No rating"
  def rating_label(""), do: "No rating"
  def rating_label(value), do: "#{value} rating"

  defp format_changeset_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map(fn {field, errors} -> "#{field}: #{Enum.join(errors, ", ")}" end)
    |> Enum.join("; ")
  end
end
