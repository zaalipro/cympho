defmodule CymphoWeb.SettingsLive.Integrations do
  use CymphoWeb, :live_view

  alias Cympho.Authentication
  alias Cympho.Agrenting
  alias Cympho.Companies
  alias Cympho.Mcp.Server, as: McpServer

  @impl true
  def mount(_params, _session, socket) do
    status = load_agrenting_status(socket)
    mcp_status = load_mcp_status(socket)

    {:ok,
     socket
     |> assign(:page_title, "Integrations")
     |> assign(:agrenting_status, status)
     |> assign(:agrenting_form, agrenting_form(status))
     |> assign(:agrenting_test_result, nil)
     |> assign(:mcp_status, mcp_status)
     |> assign(:mcp_key_form, mcp_key_form(mcp_status))
     |> assign(:mcp_key_result, nil)}
  end

  @impl true
  def handle_event("save_agrenting", %{"agrenting" => params}, socket) do
    case Agrenting.save_company_config(current_company_id(socket), params) do
      {:ok, status} ->
        {:noreply,
         socket
         |> assign(:agrenting_status, status)
         |> assign(:agrenting_form, agrenting_form(status))
         |> assign(:agrenting_test_result, nil)
         |> put_flash(:info, "Agrenting connection saved")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, agrenting_error(reason))}
    end
  end

  def handle_event("test_agrenting", _params, socket) do
    result = Agrenting.test_connection(current_company_id(socket))

    socket =
      case result do
        {:ok, %{agent_count: count}} ->
          socket
          |> assign(:agrenting_test_result, result)
          |> put_flash(:info, "Agrenting connected. Found #{count} marketplace agents.")

        {:error, reason} ->
          socket
          |> assign(:agrenting_test_result, result)
          |> put_flash(:error, "Agrenting test failed: #{agrenting_error(reason)}")
      end

    {:noreply, socket}
  end

  def handle_event("disconnect_agrenting", _params, socket) do
    :ok = Agrenting.disconnect(current_company_id(socket))
    status = load_agrenting_status(socket)

    {:noreply,
     socket
     |> assign(:agrenting_status, status)
     |> assign(:agrenting_form, agrenting_form(status))
     |> assign(:agrenting_test_result, nil)
     |> put_flash(:info, "Agrenting disconnected")}
  end

  def handle_event("create_mcp_key", %{"mcp_key" => params}, socket) do
    case create_mcp_key(socket, params) do
      {:ok, result} ->
        mcp_status = load_mcp_status(socket)

        {:noreply,
         socket
         |> assign(:mcp_status, mcp_status)
         |> assign(:mcp_key_form, mcp_key_form(mcp_status))
         |> assign(:mcp_key_result, result)
         |> put_flash(:info, "MCP API key created. Copy it now; it will not be shown again.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, mcp_error(reason))}
    end
  end

  defp current_company_id(%{assigns: %{current_company: %{id: id}}}), do: id
  defp current_company_id(_socket), do: nil

  defp load_mcp_status(socket) do
    company_id = current_company_id(socket)
    agents = if company_id, do: Companies.list_company_agents(company_id), else: []
    api_keys = Enum.flat_map(agents, &Authentication.list_agent_api_keys(&1.id))
    tools = McpServer.tools()
    ceo_count = Enum.count(agents, &(&1.role == :ceo))
    recommended_agent = Enum.find(agents, &(&1.role == :ceo)) || List.first(agents)

    %{
      agents: agents,
      api_keys: api_keys,
      tools: tools,
      agent_count: length(agents),
      ceo_count: ceo_count,
      api_key_count: length(api_keys),
      tool_count: length(tools),
      status: mcp_status(length(agents), length(api_keys)),
      next_action: mcp_next_action(length(agents), length(api_keys), ceo_count),
      setup_steps: mcp_setup_steps(length(agents), length(api_keys), ceo_count, length(tools)),
      intake_example: mcp_intake_example(recommended_agent)
    }
  end

  defp mcp_status(0, _api_key_count),
    do: %{
      tone: :blocked,
      label: "No agents",
      detail: "Create an agent before exposing MCP tools."
    }

  defp mcp_status(_agent_count, 0),
    do: %{
      tone: :attention,
      label: "Key required",
      detail: "Create a scoped agent API key before connecting an external AI client."
    }

  defp mcp_status(_agent_count, api_key_count),
    do: %{
      tone: :ready,
      label: "Ready",
      detail: "#{api_key_count} agent API keys can authenticate MCP clients."
    }

  defp mcp_next_action(0, _api_key_count, _ceo_count),
    do: "Create a CEO or routing agent, then mint a scoped MCP key for that identity."

  defp mcp_next_action(_agent_count, 0, _ceo_count),
    do: "Create a scoped API key for the agent identity your external client should act as."

  defp mcp_next_action(_agent_count, _api_key_count, 0),
    do:
      "Create a CEO agent before using the CEO intake recipe; otherwise route to an existing role."

  defp mcp_next_action(_agent_count, _api_key_count, _ceo_count),
    do:
      "Use create_issue with assigned_role \"ceo\" to land external requests directly in CEO review."

  defp mcp_setup_steps(agent_count, api_key_count, ceo_count, tool_count) do
    [
      %{
        label: "Agent identity",
        tone: if(agent_count > 0, do: :ready, else: :blocked),
        state: if(agent_count > 0, do: "Ready", else: "Missing"),
        detail:
          if(agent_count > 0,
            do: "#{agent_count} company agent identity can own external calls.",
            else: "Create a CEO or routing agent before exposing tools."
          )
      },
      %{
        label: "Scoped API key",
        tone: if(api_key_count > 0, do: :ready, else: :attention),
        state: if(api_key_count > 0, do: "Ready", else: "Create key"),
        detail:
          if(api_key_count > 0,
            do: "#{api_key_count} scoped key can authenticate MCP clients.",
            else: "Mint a key for the agent identity your external client should use."
          )
      },
      %{
        label: "CEO routing",
        tone: if(ceo_count > 0, do: :ready, else: :attention),
        state: if(ceo_count > 0, do: "Ready", else: "Needs CEO"),
        detail:
          if(ceo_count > 0,
            do: "External requests can land directly in CEO review.",
            else: "Add a CEO agent before using the default intake recipe."
          )
      },
      %{
        label: "Tool catalog",
        tone: if(tool_count > 0, do: :ready, else: :blocked),
        state: if(tool_count > 0, do: "#{tool_count} tools", else: "Unavailable"),
        detail:
          if(tool_count > 0,
            do: "Tool discovery and tool-call routes are available.",
            else: "No MCP tools are registered."
          )
      }
    ]
  end

  defp mcp_intake_example(agent) do
    args =
      %{
        "title" => "Define the next owner-visible execution plan",
        "description" =>
          "Summarize the owner request, success criteria, constraints, and the decision the CEO should make first.",
        "priority" => "high",
        "assigned_role" => "ceo"
      }
      |> maybe_put_mcp_assignee(agent)

    Jason.encode!(%{"tool" => "create_issue", "args" => args}, pretty: true)
  end

  defp maybe_put_mcp_assignee(args, %{role: :ceo, id: id}) when is_binary(id) do
    Map.put(args, "assignee_id", id)
  end

  defp maybe_put_mcp_assignee(args, _agent), do: args

  defp mcp_key_form(%{agents: agents}) when is_list(agents) and agents != [] do
    agent = Enum.find(agents, &(&1.role == :ceo)) || List.first(agents)
    to_form(%{"agent_id" => agent.id, "name" => "MCP client"}, as: :mcp_key)
  end

  defp mcp_key_form(_status),
    do: to_form(%{"agent_id" => "", "name" => "MCP client"}, as: :mcp_key)

  defp create_mcp_key(socket, params) do
    company_id = current_company_id(socket)
    agent_id = params["agent_id"]
    name = params["name"] || "MCP client"

    cond do
      is_nil(company_id) ->
        {:error, :missing_company}

      not agent_belongs_to_company?(socket.assigns.mcp_status.agents, agent_id) ->
        {:error, :invalid_agent}

      String.trim(name) == "" ->
        {:error, :missing_key_name}

      true ->
        case Authentication.create_agent_api_key(agent_id, String.trim(name)) do
          {:ok, {api_key, plain_text_key}} ->
            agent = Enum.find(socket.assigns.mcp_status.agents, &(&1.id == agent_id))

            {:ok,
             %{
               api_key: api_key,
               agent: agent,
               plain_text_key: plain_text_key,
               tools_path: "/api/mcp/tools",
               call_path: "/api/mcp/call"
             }}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp agent_belongs_to_company?(agents, agent_id) when is_binary(agent_id) do
    Enum.any?(agents, &(&1.id == agent_id))
  end

  defp agent_belongs_to_company?(_agents, _agent_id), do: false

  defp load_agrenting_status(socket) do
    socket
    |> current_company_id()
    |> Agrenting.connection_status()
  end

  defp agrenting_form(status) do
    to_form(
      %{
        "api_key" => "",
        "base_url" => status.base_url,
        "repo_access_token" => ""
      },
      as: :agrenting
    )
  end

  defp agrenting_connected?(status), do: Map.get(status, :connected?, false)
  defp api_key_present?(status), do: Map.get(status, :api_key_present?, false)
  defp custom_base_url?(status), do: Map.get(status, :base_url_custom?, false)
  defp repo_token_present?(status), do: Map.get(status, :repo_token_present?, false)

  defp connection_badge_class(status) do
    if agrenting_connected?(status) do
      "border-success/25 bg-success/10 text-success"
    else
      "border-border bg-surface text-text-tertiary"
    end
  end

  defp connection_badge_label(status) do
    if agrenting_connected?(status), do: "Connected", else: "Not connected"
  end

  defp present_label(true), do: "Stored"
  defp present_label(false), do: "Not stored"

  defp test_result_label(nil), do: nil
  defp test_result_label({:ok, %{agent_count: count}}), do: "Test passed. #{count} agents found."
  defp test_result_label({:error, reason}), do: "Test failed. #{agrenting_error(reason)}"

  defp agrenting_error(:api_key_required), do: "Enter an Agrenting API key to connect."
  defp agrenting_error(:invalid_base_url), do: "Base URL must start with http:// or https://."
  defp agrenting_error(:missing_company), do: "Select a company before connecting Agrenting."
  defp agrenting_error(:not_configured), do: "Add an Agrenting API key first."

  defp agrenting_error(%Ecto.Changeset{} = changeset) do
    changeset.errors
    |> Enum.map(fn {field, {message, _opts}} -> "#{field} #{message}" end)
    |> Enum.join(", ")
    |> case do
      "" -> "Agrenting settings could not be saved."
      message -> message
    end
  end

  defp agrenting_error(_reason), do: "Agrenting did not accept the connection."

  defp mcp_tone_class(:ready), do: "border-success/25 bg-success/10 text-success"
  defp mcp_tone_class(:attention), do: "border-amber-500/25 bg-amber-500/10 text-amber-200"
  defp mcp_tone_class(:blocked), do: "border-red-500/25 bg-red-500/10 text-red-300"
  defp mcp_tone_class(_tone), do: "border-border bg-surface text-text-tertiary"

  defp mcp_step_card_class(:ready), do: "border-success/20 bg-success/[0.06]"
  defp mcp_step_card_class(:attention), do: "border-amber-500/20 bg-amber-500/[0.06]"
  defp mcp_step_card_class(:blocked), do: "border-red-500/20 bg-red-500/[0.06]"
  defp mcp_step_card_class(_tone), do: "border-border bg-surface"

  defp mcp_error(:missing_company), do: "Select a company before creating MCP keys."
  defp mcp_error(:invalid_agent), do: "Choose an agent from this company."
  defp mcp_error(:missing_key_name), do: "Name the MCP key before creating it."

  defp mcp_error(%Ecto.Changeset{} = changeset) do
    changeset.errors
    |> Enum.map(fn {field, {message, _opts}} -> "#{field} #{message}" end)
    |> Enum.join(", ")
    |> case do
      "" -> "MCP key could not be created."
      message -> message
    end
  end

  defp mcp_error(_reason), do: "MCP key could not be created."
end
