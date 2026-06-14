defmodule CymphoWeb.SecretsLive.Index do
  use CymphoWeb, :live_view
  alias Cympho.Secrets
  alias Cympho.Secrets.Secret
  alias CymphoWeb.UserAuth

  @runtime_credential_profiles [
    %{
      id: "qwen-dashscope",
      title: "CEO Qwen runtime",
      summary: "OpenAI-compatible DashScope execution for CEO and executive agents.",
      profile: "OpenAI Chat Qwen DashScope Flash / Plus / Intl",
      primary_key: "DASHSCOPE_API_KEY",
      keys: ["DASHSCOPE_API_KEY", "ANTHROPIC_API_KEY", "OPENAI_API_KEY"],
      model: "qwen3.6-flash for smoke, qwen3.7-plus for planning",
      endpoint: "dashscope.aliyuncs.com or dashscope-intl.aliyuncs.com compatible mode",
      description: "DashScope compatible-mode runtime credential",
      icon: "hero-sparkles-mini"
    },
    %{
      id: "claude-compatible",
      title: "Claude Code runtime",
      summary: "Anthropic-compatible execution for Claude Code adapters and wrapper commands.",
      profile: "Claude-compatible",
      primary_key: "ANTHROPIC_API_KEY",
      keys: ["ANTHROPIC_API_KEY"],
      model: "Wrapper or ANTHROPIC_MODEL",
      endpoint: "ANTHROPIC_BASE_URL or wrapper default",
      description: "Anthropic-compatible runtime credential",
      icon: "hero-command-line-mini"
    },
    %{
      id: "codex",
      title: "Codex agents",
      summary: "OpenAI/Codex credentials for coding agents and hosted model execution.",
      profile: "Codex runtime",
      primary_key: "OPENAI_API_KEY",
      keys: ["OPENAI_API_KEY", "CODEX_API_KEY"],
      model: "Agent profile default",
      endpoint: "OpenAI-compatible API",
      description: "OpenAI or Codex runtime credential",
      icon: "hero-cpu-chip-mini"
    },
    %{
      id: "agrenting",
      title: "Remote marketplace agents",
      summary: "Agrenting marketplace hires and remote execution handoffs.",
      profile: "Agrenting remote",
      primary_key: "AGRENTING_API_KEY",
      keys: ["AGRENTING_API_KEY"],
      model: "Marketplace agent",
      endpoint: "Agrenting integration base URL",
      description: "Agrenting remote agent credential",
      icon: "hero-user-plus-mini"
    }
  ]

  @impl true
  def mount(%{"company_id" => company_id}, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Secrets Management")
      |> assign(:company_id, company_id)
      |> assign(:infinite_scroll, %{})
      |> assign(:selected_secret, nil)
      |> assign(:show_form, false)
      |> assign(:form_mode, :create)
      |> assign(:secret_prefill, %{})
      |> assign(:secret_action_error, nil)
      |> assign(:versions, [])
      |> assign(:show_versions, false)
      |> assign(:rotation_summary, empty_rotation_summary())
      |> assign(:runtime_credential_guide, runtime_credential_guide(company_id))
      |> load_secrets()

    {:ok, socket}
  end

  def mount(_, session, socket) do
    # Try to get company_id from current company
    company_id = get_current_company_id(socket)

    if company_id do
      mount(%{"company_id" => company_id}, session, socket)
    else
      {:ok,
       socket
       |> assign(:page_title, "Secrets Management")
       |> assign(:company_id, nil)
       |> assign(:infinite_scroll, %{})
       |> assign(:selected_secret, nil)
       |> assign(:show_form, false)
       |> assign(:form_mode, :create)
       |> assign(:secret_prefill, %{})
       |> assign(:secret_action_error, nil)
       |> assign(:versions, [])
       |> assign(:show_versions, false)
       |> assign(:rotation_summary, empty_rotation_summary())
       |> assign(:runtime_credential_guide, runtime_credential_guide(nil))
       |> init_stream(:secrets, &fetch_secrets(socket, &1))}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    case secret_prefill(params, socket.assigns.company_id) do
      nil ->
        {:noreply, socket}

      prefill ->
        {:noreply,
         socket
         |> assign(:show_form, true)
         |> assign(:form_mode, :create)
         |> assign(:selected_secret, nil)
         |> assign(:secret_prefill, prefill)
         |> assign(:secret_action_error, nil)}
    end
  end

  @impl true
  def handle_info({CymphoWeb.SecretsLive.FormComponent, {:saved, _result}}, socket) do
    return_to = safe_prefill_return_to(socket.assigns.secret_prefill)

    socket =
      socket
      |> put_flash(:info, "Secret saved successfully")
      |> assign(:show_form, false)
      |> assign(:secret_prefill, %{})
      |> assign(:secret_action_error, nil)

    if return_to do
      {:noreply, push_navigate(socket, to: return_to)}
    else
      {:noreply, load_secrets(socket)}
    end
  end

  @impl true
  def handle_event("next-page", _params, socket) do
    {:reply, %{}, load_next(socket, :secrets, &fetch_secrets(socket, &1))}
  end

  def handle_event("show_create_form", _, socket) do
    changeset = Secret.changeset(%Secret{}, %{})

    socket =
      socket
      |> assign(:show_form, true)
      |> assign(:form_mode, :create)
      |> assign(:changeset, changeset)
      |> assign(:selected_secret, nil)
      |> assign(:secret_prefill, %{})
      |> assign(:secret_action_error, nil)

    {:noreply, socket}
  end

  def handle_event("show_edit_form", %{"id" => id}, socket) do
    case get_current_company_secret(socket, id) do
      {:ok, secret} ->
        changeset = Secret.changeset(secret, %{})

        socket =
          socket
          |> assign(:show_form, true)
          |> assign(:form_mode, :edit)
          |> assign(:changeset, changeset)
          |> assign(:selected_secret, secret)
          |> assign(:secret_prefill, %{})
          |> assign(:secret_action_error, nil)

        {:noreply, socket}

      {:error, :not_found} ->
        {:noreply, secret_action_error(socket)}
    end
  end

  def handle_event("show_versions", %{"id" => id}, socket) do
    case get_current_company_secret(socket, id) do
      {:ok, secret} ->
        versions = Secrets.list_secret_versions(secret.id)

        socket =
          socket
          |> assign(:selected_secret, secret.id)
          |> assign(:versions, versions)
          |> assign(:show_versions, true)
          |> assign(:secret_action_error, nil)

        {:noreply, socket}

      {:error, :not_found} ->
        {:noreply, secret_action_error(socket)}
    end
  end

  def handle_event("hide_form", _, socket) do
    socket =
      socket
      |> assign(:show_form, false)
      |> assign(:changeset, nil)
      |> assign(:secret_prefill, %{})
      |> assign(:secret_action_error, nil)

    {:noreply, socket}
  end

  def handle_event("hide_versions", _, socket) do
    socket =
      socket
      |> assign(:show_versions, false)
      |> assign(:versions, [])
      |> assign(:secret_action_error, nil)

    {:noreply, socket}
  end

  def handle_event("save", %{"secret" => secret_params}, socket) do
    company_id = socket.assigns.company_id

    secret_params = Map.put(secret_params, "company_id", company_id)

    result =
      case socket.assigns.form_mode do
        :create -> Secrets.create_secret(secret_params)
        :edit -> Secrets.update_secret(socket.assigns.selected_secret, secret_params)
      end

    case result do
      {:ok, _secret} ->
        socket =
          socket
          |> put_flash(:info, "Secret saved successfully")
          |> assign(:show_form, false)
          |> assign(:secret_prefill, %{})
          |> assign(:secret_action_error, nil)
          |> load_secrets()

        {:noreply, socket}

      {:error, changeset} ->
        socket =
          socket
          |> put_flash(:error, "Failed to save secret")
          |> assign(:changeset, changeset)

        {:noreply, socket}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case get_current_company_secret(socket, id) do
      {:ok, secret} ->
        case Secrets.delete_secret(secret) do
          {:ok, _} ->
            socket =
              socket
              |> put_flash(:info, "Secret deleted successfully")
              |> assign(:secret_action_error, nil)
              |> load_secrets()

            {:noreply, socket}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete secret")}
        end

      {:error, _} ->
        {:noreply, secret_action_error(socket)}
    end
  end

  def handle_event("rotate", %{"id" => id}, socket) do
    case get_current_company_secret(socket, id) do
      {:ok, secret} ->
        # For rotation, we'd typically show a modal to enter new value
        # For now, we'll open the edit form
        changeset = Secret.changeset(secret, %{})

        socket =
          socket
          |> assign(:show_form, true)
          |> assign(:form_mode, :rotate)
          |> assign(:changeset, changeset)
          |> assign(:selected_secret, secret)
          |> assign(:secret_prefill, %{})
          |> assign(:secret_action_error, nil)

        {:noreply, socket}

      {:error, _} ->
        {:noreply, secret_action_error(socket)}
    end
  end

  defp load_secrets(socket) do
    socket
    |> assign(:rotation_summary, rotation_summary(socket.assigns[:company_id]))
    |> assign(:runtime_credential_guide, runtime_credential_guide(socket.assigns[:company_id]))
    |> reset_stream(:secrets, &fetch_secrets(socket, &1))
  end

  defp rotation_summary(company_id) when is_binary(company_id),
    do: Secrets.rotation_summary(company_id)

  defp rotation_summary(_company_id), do: empty_rotation_summary()

  defp empty_rotation_summary do
    %{
      total: 0,
      fresh: 0,
      due_soon: 0,
      overdue: 0,
      unknown: 0,
      needs_rotation: 0,
      by_scope: %{}
    }
  end

  defp fetch_secrets(socket, cursor) do
    case socket.assigns[:company_id] do
      nil -> %Cympho.Pagination.Page{entries: [], next_cursor: nil, has_more?: false}
      company_id -> Secrets.list_secrets_page(company_id, after: cursor)
    end
  end

  defp get_current_company_id(socket) do
    case socket.assigns do
      %{current_company: %{id: id}} -> id
      %{current_user: %{company_id: id}} -> id
      _ -> nil
    end
  end

  defp get_current_company_secret(socket, id) do
    case socket.assigns[:company_id] do
      company_id when is_binary(company_id) -> Secrets.get_company_secret(company_id, id)
      _ -> {:error, :not_found}
    end
  end

  defp secret_action_error(socket) do
    socket
    |> put_flash(:error, "Secret not found")
    |> assign(:secret_action_error, "Secret not found")
  end

  defp secret_prefill(%{"key" => key} = params, company_id)
       when is_binary(company_id) and is_binary(key) do
    key = String.trim(key)

    if key == "" do
      nil
    else
      params
      |> Map.take(["scope", "scope_id", "description", "return_to"])
      |> Map.put("key", key)
      |> Map.update("scope", "company", &valid_scope/1)
      |> drop_blank_scope_id()
      |> drop_unsafe_return_to()
    end
  end

  defp secret_prefill(_params, _company_id), do: nil

  defp valid_scope(scope) when scope in ["company", "instance", "agent", "project"], do: scope
  defp valid_scope(_scope), do: "company"

  defp drop_blank_scope_id(%{"scope_id" => scope_id} = attrs) when scope_id in [nil, ""] do
    Map.delete(attrs, "scope_id")
  end

  defp drop_blank_scope_id(attrs), do: attrs

  defp drop_unsafe_return_to(%{"return_to" => return_to} = attrs) do
    case UserAuth.safe_return_path(return_to) do
      nil -> Map.delete(attrs, "return_to")
      path -> Map.put(attrs, "return_to", path)
    end
  end

  defp drop_unsafe_return_to(attrs), do: attrs

  defp safe_prefill_return_to(%{"return_to" => return_to}),
    do: UserAuth.safe_return_path(return_to)

  defp safe_prefill_return_to(_prefill), do: nil

  defp scope_badge_class("company"), do: "bg-purple-500/20 text-purple-400"
  defp scope_badge_class("instance"), do: "bg-blue-500/20 text-blue-400"
  defp scope_badge_class("agent"), do: "bg-green-500/20 text-green-400"
  defp scope_badge_class("project"), do: "bg-yellow-500/20 text-yellow-400"
  defp scope_badge_class(_), do: "bg-gray-500/20 text-gray-400"

  defp format_scope("company"), do: "Company"
  defp format_scope("instance"), do: "Instance"
  defp format_scope("agent"), do: "Agent"
  defp format_scope("project"), do: "Project"
  defp format_scope(scope), do: String.capitalize(scope)

  defp secret_rotation(%Secret{} = secret), do: Secrets.rotation_entry(secret)

  defp runtime_credential_guide(company_id) when is_binary(company_id) do
    secret_keys =
      company_id
      |> Secrets.list_secrets()
      |> Enum.map(& &1.key)
      |> MapSet.new()

    profiles =
      Enum.map(@runtime_credential_profiles, &runtime_credential_profile(&1, secret_keys))

    ready_count = Enum.count(profiles, & &1.ready)

    %{
      ready_count: ready_count,
      total_count: length(profiles),
      status: runtime_credential_status(ready_count, length(profiles)),
      summary: runtime_credential_summary(ready_count, length(profiles)),
      profiles: profiles
    }
  end

  defp runtime_credential_guide(_company_id) do
    profiles =
      Enum.map(@runtime_credential_profiles, &runtime_credential_profile(&1, MapSet.new()))

    %{
      ready_count: 0,
      total_count: length(profiles),
      status: :blocked,
      summary: "No company is selected, so runtime credentials cannot be evaluated.",
      profiles: profiles
    }
  end

  defp runtime_credential_profile(profile, secret_keys) do
    present_key = Enum.find(profile.keys, &MapSet.member?(secret_keys, &1))
    ready? = is_binary(present_key)

    profile
    |> Map.put(:ready, ready?)
    |> Map.put(:present_key, present_key)
    |> Map.put(:status_label, if(ready?, do: "Ready", else: "Missing"))
    |> Map.put(:status_detail, runtime_credential_detail(profile, present_key))
    |> Map.put(:setup_path, runtime_credential_setup_path(profile))
  end

  defp runtime_credential_status(total, total), do: :ready
  defp runtime_credential_status(0, _total), do: :blocked
  defp runtime_credential_status(_ready, _total), do: :attention

  defp runtime_credential_summary(total, total) do
    "All #{total} runtime credential lanes are ready for agent execution."
  end

  defp runtime_credential_summary(0, total) do
    "0 of #{total} runtime credential lanes are ready. Add a provider key before assigning runtime work."
  end

  defp runtime_credential_summary(ready, total) do
    "#{ready} of #{total} runtime credential lanes are ready. Add the missing keys to broaden agent coverage."
  end

  defp runtime_credential_detail(_profile, present_key) when is_binary(present_key) do
    "#{present_key} is stored as an encrypted active secret."
  end

  defp runtime_credential_detail(profile, _present_key) do
    "Add #{profile.primary_key} at company scope."
  end

  defp runtime_credential_setup_path(profile) do
    query =
      URI.encode_query(%{
        "key" => profile.primary_key,
        "scope" => "company",
        "description" => profile.description
      })

    "/settings/secrets?#{query}"
  end

  defp runtime_credential_badge_class(:ready),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"

  defp runtime_credential_badge_class(:attention),
    do: "border-amber-500/25 bg-amber-500/10 text-amber-200"

  defp runtime_credential_badge_class(:blocked),
    do: "border-red-500/25 bg-red-500/10 text-red-300"

  defp credential_profile_class(true),
    do: "border-emerald-500/20 bg-emerald-500/[0.04]"

  defp credential_profile_class(false),
    do: "border-border bg-surface"

  defp credential_profile_status_class(true),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"

  defp credential_profile_status_class(false),
    do: "border-amber-500/25 bg-amber-500/10 text-amber-200"

  defp rotation_badge_class(:fresh),
    do: "border-emerald-500/20 bg-emerald-500/10 text-emerald-300"

  defp rotation_badge_class(:due_soon), do: "border-amber-500/25 bg-amber-500/10 text-amber-200"
  defp rotation_badge_class(:overdue), do: "border-red-500/25 bg-red-500/10 text-red-300"
  defp rotation_badge_class(_), do: "border-border bg-surface text-text-tertiary"

  defp rotation_status_label(%{status: :fresh, age_days: age_days}) do
    "Fresh · #{format_age(age_days)}"
  end

  defp rotation_status_label(%{status: :due_soon, age_days: age_days}) do
    "Due soon · #{format_age(age_days)}"
  end

  defp rotation_status_label(%{status: :overdue, age_days: age_days}) do
    "Overdue · #{format_age(age_days)}"
  end

  defp rotation_status_label(_rotation), do: "Review age"

  defp format_age(nil), do: "unknown"
  defp format_age(1), do: "1 day"
  defp format_age(days), do: "#{days} days"
end
