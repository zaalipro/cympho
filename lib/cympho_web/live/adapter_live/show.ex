defmodule CymphoWeb.AdapterLive.Show do
  use CymphoWeb, :live_view

  alias Cympho.Adapters
  alias Cympho.Agents
  alias Cympho.Companies
  alias Cympho.Repo
  alias Cympho.Secrets

  @encrypted_secret_marker "__cympho_encrypted_secret__"
  @management_forbidden_message "Only company owners, admins, and board members can change adapter settings."

  @impl true
  def mount(%{"key" => key_str}, _session, socket) do
    key = String.to_existing_atom(key_str)

    case Adapters.get_adapter(key) do
      {:ok, adapter} ->
        company_id =
          case socket.assigns[:current_company] do
            %{id: company_id} -> company_id
            _ -> nil
          end

        agents =
          if company_id,
            do: Agents.list_agents_by_adapter(key, company_id),
            else: []

        config = config_for_agents(adapter.config_schema, agents, key, company_id)
        health = Adapters.check_health(key, config)

        socket =
          socket
          |> assign(:page_title, adapter.name)
          |> assign(:adapter, adapter)
          |> assign(:adapter_key, key)
          |> assign(:health, health)
          |> assign(:agents, agents)
          |> assign(:config, config)
          |> assign(:config_schema, adapter.config_schema)
          |> assign(:can_manage_adapter_settings, can_manage_adapter_settings?(socket))
          |> assign(:pending_sensitive_config, %{})
          |> assign(:validation_error, nil)
          |> assign(:test_result, nil)

        {:ok, socket}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Adapter not found")
         |> redirect(to: ~p"/settings/adapters")}
    end
  rescue
    ArgumentError ->
      {:ok,
       socket
       |> put_flash(:error, "Invalid adapter key")
       |> redirect(to: ~p"/settings/adapters")}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("test_health", _params, socket) do
    authorize_adapter_settings(socket, fn ->
      result = Adapters.check_health(socket.assigns.adapter_key, socket.assigns.config)
      {:noreply, assign(socket, health: result)}
    end)
  end

  @impl true
  def handle_event("send_test_heartbeat", _params, socket) do
    authorize_adapter_settings(socket, fn ->
      key = socket.assigns.adapter_key
      result = Adapters.check_health(key, socket.assigns.config)

      message =
        case result.status do
          :healthy -> "Configuration check passed: #{result.message || "OK"}"
          status -> "Configuration check returned #{status}: #{result.message || "no details"}"
        end

      {:noreply,
       socket
       |> assign(:health, result)
       |> assign(:test_result, result)
       |> put_flash(:info, message)}
    end)
  end

  @impl true
  def handle_event("validate_config", %{"config" => config_params}, socket) do
    authorize_adapter_settings(socket, fn ->
      {config, pending_sensitive_config} = normalized_form_config(config_params, socket)

      case Adapters.validate_config(socket.assigns.adapter_key, config) do
        :ok ->
          {:noreply,
           assign(socket,
             config: config,
             pending_sensitive_config: pending_sensitive_config,
             validation_error: nil
           )}

        {:error, reason} ->
          {:noreply,
           assign(socket,
             config: config,
             pending_sensitive_config: pending_sensitive_config,
             validation_error: reason
           )}
      end
    end)
  end

  @impl true
  def handle_event("save_config", params, socket) do
    authorize_adapter_settings(socket, fn -> save_config(params, socket) end)
  end

  defp save_config(%{"config" => config_params}, socket) do
    submitted_config = normalize_config_keys(config_params, socket.assigns.config_schema)
    submitted_config = Map.merge(submitted_config, socket.assigns.pending_sensitive_config)

    config =
      preserve_sensitive_values(
        submitted_config,
        socket.assigns.config,
        socket.assigns.config_schema
      )

    case Adapters.validate_config(socket.assigns.adapter_key, config) do
      :ok ->
        agents = socket.assigns.agents

        if agents == [] do
          message = "No agents use this adapter, so nothing was saved. Configure an agent first."

          {:noreply,
           socket
           |> assign(:config, config)
           |> assign(:validation_error, message)
           |> put_flash(:error, message)}
        else
          updates = adapter_config_updates(agents, submitted_config, socket.assigns.config_schema)

          case persist_adapter_config(socket, submitted_config, updates) do
            {:ok, updated_agents, credential_saved?} ->
              saved_config =
                config_for_agents(
                  socket.assigns.config_schema,
                  updated_agents,
                  socket.assigns.adapter_key,
                  socket.assigns.current_company.id
                )

              health = Adapters.check_health(socket.assigns.adapter_key, saved_config)

              {:noreply,
               socket
               |> assign(:agents, updated_agents)
               |> assign(:config, saved_config)
               |> assign(:pending_sensitive_config, %{})
               |> assign(:health, health)
               |> assign(:validation_error, nil)
               |> put_flash(
                 :info,
                 adapter_save_message(length(updated_agents), credential_saved?)
               )}

            {:error, :agent_config, agent_id, _reason} ->
              message = adapter_save_error(agents, agent_id)

              {:noreply,
               socket
               |> assign(:config, config)
               |> assign(:validation_error, message)
               |> put_flash(:error, message)}

            {:error, :secret, _reason} ->
              message =
                "Configuration was not saved because the API key could not be stored in encrypted company Secrets."

              {:noreply,
               socket
               |> assign(:config, config)
               |> assign(:validation_error, message)
               |> put_flash(:error, message)}
          end
        end

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:config, config)
         |> assign(:validation_error, reason)
         |> put_flash(:error, "Validation failed: #{reason}")}
    end
  end

  defp can_manage_adapter_settings?(%{
         assigns: %{
           current_user: %{id: user_id},
           current_company: %{id: company_id}
         }
       }) do
    Companies.admin?(user_id, company_id) or Companies.is_board_member?(user_id, company_id)
  end

  defp can_manage_adapter_settings?(_socket), do: false

  defp authorize_adapter_settings(socket, fun) do
    if can_manage_adapter_settings?(socket) do
      fun.()
    else
      {:noreply,
       socket
       |> assign(:can_manage_adapter_settings, false)
       |> assign(:validation_error, @management_forbidden_message)
       |> put_flash(:error, @management_forbidden_message)}
    end
  end

  defp default_config(schema) do
    schema
    |> Enum.into(%{}, fn entry ->
      {entry.key, Map.get(entry, :default)}
    end)
  end

  defp config_for_agents(schema, agents, adapter_key, company_id) do
    saved =
      agents
      |> Enum.find(fn agent -> agent.adapter == adapter_key end)
      |> case do
        nil -> %{}
        agent -> normalize_config_keys(agent.config || %{}, schema)
      end

    schema
    |> default_config()
    |> Map.merge(saved)
    |> mark_encrypted_api_key(adapter_key, company_id)
  end

  defp normalized_form_config(config_params, socket) do
    submitted = normalize_config_keys(config_params, socket.assigns.config_schema)

    pending_sensitive_config =
      retain_pending_api_key(socket.assigns.pending_sensitive_config, submitted)

    config =
      submitted
      |> Map.merge(pending_sensitive_config)
      |> preserve_sensitive_values(socket.assigns.config, socket.assigns.config_schema)

    {config, pending_sensitive_config}
  end

  defp preserve_sensitive_values(config, existing, schema) do
    Enum.reduce(schema, config, fn field, acc ->
      current = Map.get(existing, field.key)

      if sensitive_field?(field) and Map.get(acc, field.key) in [nil, ""] and
           current not in [nil, ""] do
        Map.put(acc, field.key, current)
      else
        acc
      end
    end)
  end

  defp adapter_config_updates(agents, submitted_config, schema) do
    field_updates = submitted_field_updates(submitted_config, schema)
    replace_api_key? = submitted_api_key?(submitted_config)

    Enum.map(agents, fn agent ->
      existing = drop_replaced_aliases(agent.config || %{}, field_updates)

      existing =
        if replace_api_key?, do: Map.drop(existing, ["api_key", :api_key]), else: existing

      {agent, Map.merge(existing, field_updates)}
    end)
  end

  defp submitted_field_updates(config, schema) do
    fields = Map.new(schema, &{&1.key, &1})

    Enum.reduce(config, %{}, fn {key, value}, acc ->
      field = Map.fetch!(fields, key)

      cond do
        field.key == :api_key ->
          acc

        sensitive_field?(field) and value in [nil, ""] ->
          acc

        true ->
          Map.put(acc, to_string(key), value)
      end
    end)
  end

  defp retain_pending_api_key(pending, submitted) do
    case Map.get(submitted, :api_key) do
      value when is_binary(value) ->
        if String.trim(value) == "", do: pending, else: Map.put(pending, :api_key, value)

      _value ->
        pending
    end
  end

  defp persist_submitted_api_key(socket, submitted_config) do
    if submitted_api_key?(submitted_config) do
      company_id = socket.assigns.current_company.id

      secret_keys = api_key_secret_keys(socket.assigns.adapter_key, submitted_config)
      primary_secret_key = hd(secret_keys)
      value = Map.fetch!(submitted_config, :api_key)

      case existing_api_key_secret(company_id, secret_keys) do
        {:ok, secret} ->
          case Secrets.rotate_secret(secret, value) do
            {:ok, _changes} -> {:ok, true}
            {:error, _operation, reason, _changes} -> {:error, reason}
          end

        {:error, :not_found} ->
          case Secrets.create_secret(%{
                 company_id: company_id,
                 scope: "company",
                 key: primary_secret_key,
                 value: value,
                 description: "#{socket.assigns.adapter.name} credential from Adapter Settings"
               }) do
            {:ok, _secret} -> {:ok, true}
            {:error, reason} -> {:error, reason}
          end
      end
    else
      {:ok, false}
    end
  end

  defp submitted_api_key?(config) do
    case Map.get(config, :api_key) do
      value when is_binary(value) -> String.trim(value) != ""
      _value -> false
    end
  end

  defp persist_adapter_config(socket, submitted_config, updates) do
    result =
      Repo.transaction(fn ->
        with {:ok, credential_saved?} <- persist_submitted_api_key(socket, submitted_config),
             {:ok, updated_agents} <- Agents.update_adapter_configs(updates) do
          {updated_agents, credential_saved?}
        else
          {:error, agent_id, reason} -> Repo.rollback({:agent_config, agent_id, reason})
          {:error, reason} -> Repo.rollback({:secret, reason})
        end
      end)

    case result do
      {:ok, {updated_agents, credential_saved?}} ->
        {:ok, updated_agents, credential_saved?}

      {:error, {operation, detail}} ->
        {:error, operation, detail}

      {:error, {:agent_config, agent_id, reason}} ->
        {:error, :agent_config, agent_id, reason}
    end
  end

  defp existing_api_key_secret(company_id, secret_keys) do
    Enum.find_value(secret_keys, {:error, :not_found}, fn secret_key ->
      case Secrets.get_secret_by_key(company_id, secret_key, scope: "company") do
        {:ok, secret} -> {:ok, secret}
        {:error, :not_found} -> false
      end
    end)
  end

  defp mark_encrypted_api_key(config, adapter_key, company_id) when is_binary(company_id) do
    cond do
      Map.get(config, :api_key) not in [nil, ""] ->
        config

      Enum.any?(api_key_secret_keys(adapter_key, config), fn secret_key ->
        match?(
          {:ok, _secret},
          Secrets.get_secret_by_key(company_id, secret_key, scope: "company")
        )
      end) ->
        Map.put(config, :api_key, @encrypted_secret_marker)

      true ->
        config
    end
  end

  defp mark_encrypted_api_key(config, _adapter_key, _company_id), do: config

  defp api_key_secret_keys(:claude_code, _config), do: ["ANTHROPIC_API_KEY"]
  defp api_key_secret_keys(:codex, _config), do: ["OPENAI_API_KEY"]
  defp api_key_secret_keys(:openclaw, _config), do: ["OPENCLAW_API_KEY"]
  defp api_key_secret_keys(:agrenting, _config), do: ["AGRENTING_API_KEY"]

  defp api_key_secret_keys(:openai_chat, config) do
    endpoint = config_value(config, :endpoint) |> to_string() |> String.downcase()
    model = config_value(config, :model) |> to_string() |> String.downcase()

    cond do
      String.contains?(endpoint, "llmotions") ->
        ["LLMOTIONS_API_KEY", "OPENAI_API_KEY", "DASHSCOPE_API_KEY", "ANTHROPIC_API_KEY"]

      String.contains?(endpoint, "dashscope") or String.starts_with?(model, "qwen") ->
        ["DASHSCOPE_API_KEY", "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "LLMOTIONS_API_KEY"]

      true ->
        ["OPENAI_API_KEY", "DASHSCOPE_API_KEY", "ANTHROPIC_API_KEY", "LLMOTIONS_API_KEY"]
    end
  end

  defp api_key_secret_keys(_adapter_key, _config), do: ["OPENAI_API_KEY"]

  defp config_value(config, key) do
    Map.get(config, key) || Map.get(config, to_string(key))
  end

  defp adapter_save_message(agent_count, true) do
    "Configuration saved for #{agent_count} agent(s). API key stored in encrypted company Secrets."
  end

  defp adapter_save_message(agent_count, false) do
    "Configuration saved for #{agent_count} agent(s)"
  end

  defp drop_replaced_aliases(existing, %{"timeout_sec" => _value}) do
    Map.drop(existing, ["timeout", "timeout_ms", :timeout, :timeout_ms])
  end

  defp drop_replaced_aliases(existing, _field_updates), do: existing

  defp adapter_save_error(agents, agent_id) do
    agent_name =
      agents
      |> Enum.find(&(&1.id == agent_id))
      |> case do
        nil -> "An assigned agent"
        agent -> agent.name
      end

    "Configuration was not saved. #{agent_name} could not be updated, so no changes were applied."
  end

  defp normalize_config_keys(params, schema) when is_map(params) do
    allowed_keys =
      Map.new(schema, fn entry ->
        {Atom.to_string(entry.key), entry}
      end)

    params
    |> Enum.flat_map(fn {k, v} ->
      case Map.fetch(allowed_keys, to_string(k)) do
        {:ok, field} -> [{field.key, parse_config_value(v, field.type)}]
        :error -> []
      end
    end)
    |> Map.new()
  end

  defp parse_config_value("", _type), do: nil

  defp parse_config_value(value, :integer) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> integer
      _ -> value
    end
  end

  defp parse_config_value(value, :float) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {float, ""} -> float
      _ -> value
    end
  end

  defp parse_config_value(value, :boolean) when value in ["true", "on", "1"], do: true
  defp parse_config_value(value, :boolean) when value in ["false", "0"], do: false

  defp parse_config_value(value, type) when type in [:map, :list] and is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> value
    end
  end

  defp parse_config_value(value, _type), do: value

  defp visible_config_schema(schema) do
    keys = MapSet.new(schema, & &1.key)

    if MapSet.member?(keys, :timeout_sec) do
      Enum.reject(schema, &(&1.key in [:timeout, :timeout_ms]))
    else
      schema
    end
  end

  defp health_status_class(:healthy), do: "bg-success/20 text-success"
  defp health_status_class(:degraded), do: "bg-amber-500/20 text-amber-400"
  defp health_status_class(:unhealthy), do: "bg-brand/20 text-brand"
  defp health_status_class(_), do: "bg-text-quaternary/20 text-text-quaternary"

  defp health_dot_class(:healthy), do: "bg-success animate-pulse"
  defp health_dot_class(:degraded), do: "bg-amber-400 animate-pulse"
  defp health_dot_class(:unhealthy), do: "bg-brand animate-pulse"
  defp health_dot_class(_), do: "bg-text-quaternary"

  defp health_status_label(:healthy), do: "Healthy"
  defp health_status_label(:degraded), do: "Degraded"
  defp health_status_label(:unhealthy), do: "Unhealthy"
  defp health_status_label(_), do: "Unknown"

  # nil when the role would just repeat the agent name above it ("CEO" / "Ceo").
  defp distinct_role_label(agent) do
    label =
      agent.role
      |> Atom.to_string()
      |> String.replace("_", " ")
      |> String.capitalize()

    if String.downcase(label) == String.downcase(agent.name || ""), do: nil, else: label
  end

  defp format_datetime(nil), do: "Never"
  defp format_datetime(dt), do: CymphoWeb.Format.format_datetime(dt)

  defp input_type(field) do
    cond do
      sensitive_field?(field) -> "password"
      field.type == :integer -> "number"
      field.type == :boolean -> "checkbox"
      field.type == :float -> "number"
      true -> "text"
    end
  end

  defp input_autocomplete(field), do: if(sensitive_field?(field), do: "new-password", else: nil)

  defp input_step(%{type: :float}), do: "any"
  defp input_step(_field), do: nil

  defp input_placeholder(field, config) do
    cond do
      sensitive_field?(field) and Map.get(config, field.key) not in [nil, ""] ->
        "Configured — leave blank to keep"

      field.default ->
        inspect(field.default)

      true ->
        ""
    end
  end

  defp field_input_value(field, config) do
    cond do
      field.type == :boolean -> "true"
      sensitive_field?(field) -> ""
      true -> input_value(Map.get(config, field.key))
    end
  end

  defp field_checked?(%{type: :boolean} = field, config),
    do: Map.get(config, field.key) in [true, "true", "on", "1"]

  defp field_checked?(_field, _config), do: false

  defp field_required?(field, config) do
    field.required and
      not (sensitive_field?(field) and Map.get(config, field.key) not in [nil, ""])
  end

  defp sensitive_field?(field) do
    key = field.key |> to_string() |> String.downcase()

    key in ["api_key", "password", "secret", "token"] or
      String.ends_with?(key, ["_api_key", "_password", "_secret", "_token"])
  end

  # Map/list config values (e.g. process/http adapter env defaults) are not
  # valid HTML attribute values — render them as JSON text.
  defp input_value(nil), do: ""
  defp input_value(value) when is_map(value) or is_list(value), do: Jason.encode!(value)
  defp input_value(value), do: value
end
