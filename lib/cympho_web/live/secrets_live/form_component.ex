defmodule CymphoWeb.SecretsLive.FormComponent do
  use CymphoWeb, :live_component
  alias Cympho.Secrets
  alias Cympho.Secrets.Secret
  alias CymphoWeb.UserAuth

  @mutation_forbidden_message "Only company owners, admins, and board members can change secrets."

  @impl true
  def update(%{secret: secret, form_mode: form_mode, company_id: company_id} = assigns, socket) do
    prefill = Map.get(assigns, :prefill, %{})
    return_to = assigns |> Map.get(:return_to) |> UserAuth.safe_return_path()

    changeset =
      case {form_mode, secret} do
        {:edit, %Secret{} = secret} -> Secret.changeset(secret, %{})
        {:rotate, %Secret{} = secret} -> Secret.changeset(secret, %{})
        {:create, nil} -> Secret.changeset(%Secret{}, Map.put(prefill, "company_id", company_id))
        _ -> Secret.changeset(%Secret{}, %{})
      end

    form = to_form(changeset, as: :secret)

    socket =
      socket
      |> assign(:secret, secret)
      |> assign(:form_mode, form_mode)
      |> assign(:company_id, company_id)
      |> assign(:current_user_id, Map.get(assigns, :current_user_id))
      |> assign(:on_cancel, Map.get(assigns, :on_cancel))
      |> assign(:return_to, return_to)
      |> assign(:runtime_hint, runtime_hint(prefill))
      |> assign(:mutation_error, socket.assigns[:mutation_error])
      |> assign(:form, form)

    {:ok, socket}
  end

  @impl true
  def handle_event("validate", %{"secret" => secret_params}, socket) do
    form =
      %Secret{}
      |> Secret.changeset(secret_params)
      |> Map.put(:action, :validate)
      |> to_form(as: :secret)

    {:noreply, assign(socket, :form, form)}
  end

  def handle_event("save", %{"secret" => secret_params}, socket) do
    if can_manage_secrets?(socket) do
      save_secret(secret_params, socket)
    else
      {:noreply, assign(socket, :mutation_error, @mutation_forbidden_message)}
    end
  end

  defp save_secret(secret_params, socket) do
    company_id = socket.assigns.company_id
    secret_params = Map.put(secret_params, "company_id", company_id)

    result =
      case socket.assigns.form_mode do
        :create ->
          Secrets.create_secret(secret_params)

        :edit ->
          Secrets.update_secret(socket.assigns.secret, secret_params)

        :rotate ->
          case blank_to_nil(secret_params["value"] || secret_params[:value]) do
            nil ->
              {:error,
               Secret.changeset(socket.assigns.secret, %{})
               |> Ecto.Changeset.add_error(:value, "can't be blank")}

            new_value ->
              Secrets.rotate_secret(socket.assigns.secret, new_value)
          end
      end

    case result do
      {:ok, secret} ->
        case socket.assigns.return_to do
          path when is_binary(path) and path != "" ->
            {:noreply,
             socket
             |> put_flash(:info, "Secret saved successfully")
             |> push_navigate(to: path)}

          _ ->
            send(self(), {__MODULE__, {:saved, secret}})
            {:noreply, socket}
        end

      {:error, :value_required} ->
        changeset =
          socket.assigns.secret
          |> Secret.changeset(%{})
          |> Ecto.Changeset.add_error(:value, "can't be blank")

        {:noreply, assign(socket, :form, to_form(changeset, as: :secret))}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :secret))}
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp blank_to_nil(value), do: value

  defp can_manage_secrets?(%{
         assigns: %{current_user_id: user_id, company_id: company_id}
       })
       when is_binary(user_id) and is_binary(company_id) do
    Cympho.CompanyRBAC.manager?(user_id, company_id)
  end

  defp can_manage_secrets?(_socket), do: false

  @impl true
  def render(assigns) do
    ~H"""
    <section
      id="secret-form-panel"
      class="mb-6 overflow-hidden rounded-lg border border-border bg-panel"
    >
      <div
        :if={@mutation_error}
        data-testid="secret-form-authorization-error"
        class="border-b border-red-500/25 bg-red-500/10 px-5 py-3 text-sm text-red-200"
      >
        {@mutation_error}
      </div>
      <div
        :if={@runtime_hint}
        id="runtime-secret-setup-guide"
        data-testid="runtime-secret-setup-guide"
        class="border-b border-brand/20 bg-brand/[0.08] px-5 py-4"
      >
        <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
          <div class="min-w-0">
            <p class="text-[11px] font-590 uppercase tracking-[0.14em] text-brand">
              {@runtime_hint.title}
            </p>
            <p class="mt-2 max-w-2xl text-sm leading-5 text-text-secondary">
              {@runtime_hint.summary}
            </p>
          </div>
          <span class="inline-flex shrink-0 items-center gap-1.5 rounded-full border border-brand/25 bg-panel/80 px-2.5 py-1 text-xs font-510 text-brand">
            <.icon name="hero-shield-check" class="h-3.5 w-3.5" />
            {@runtime_hint.profile}
          </span>
        </div>

        <dl class="mt-4 grid gap-2 border-t border-brand/15 pt-3 sm:grid-cols-2">
          <div
            :for={item <- @runtime_hint.items}
            class="min-w-0 rounded-md border border-brand/15 bg-panel/75 px-3 py-2"
          >
            <dt class="text-[10px] font-590 uppercase tracking-[0.1em] text-text-quaternary">
              {item.label}
            </dt>
            <dd class="mt-1 break-words text-xs text-text-secondary">{item.value}</dd>
          </div>
        </dl>

        <div class="mt-3 grid gap-2 sm:grid-cols-3">
          <div class="rounded-md border border-brand/15 bg-panel/70 px-3 py-2">
            <p class="text-[10px] font-590 uppercase tracking-[0.1em] text-text-quaternary">
              Save effect
            </p>
            <p class="mt-1 text-xs leading-5 text-text-secondary">
              {@runtime_hint.save_effect}
            </p>
          </div>
          <div class="rounded-md border border-brand/15 bg-panel/70 px-3 py-2">
            <p class="text-[10px] font-590 uppercase tracking-[0.1em] text-text-quaternary">
              Security
            </p>
            <p class="mt-1 text-xs leading-5 text-text-secondary">
              Encrypted at rest; the value is never shown after save.
            </p>
          </div>
          <div class="rounded-md border border-brand/15 bg-panel/70 px-3 py-2">
            <p class="text-[10px] font-590 uppercase tracking-[0.1em] text-text-quaternary">
              Next
            </p>
            <p class="mt-1 text-xs leading-5 text-text-secondary">
              {@runtime_hint.next_step}
            </p>
          </div>
        </div>

        <p
          :if={@return_to}
          class="mt-3 inline-flex rounded-md border border-brand/15 bg-panel/60 px-3 py-1.5 text-xs text-text-secondary"
        >
          After saving, Cympho returns to the runtime page that requested this credential.
        </p>
      </div>

      <div class="px-5 py-4">
        <div class="mb-4 flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between">
          <div>
            <p class="font-serif text-base font-510 text-text-primary">{form_title(@form_mode)}</p>
            <p class="mt-1 text-xs leading-5 text-text-tertiary">
              Use company scope for provider keys unless a single agent or project needs a separate quota.
            </p>
          </div>
          <span class="inline-flex w-fit rounded-full border border-border bg-surface px-2.5 py-1 text-[11px] font-510 text-text-tertiary">
            No provider call on save
          </span>
        </div>

        <.form
          for={@form}
          phx-target={@myself}
          phx-change="validate"
          phx-submit="save"
          id="secret-form"
        >
          <div class="grid grid-cols-1 gap-4 md:grid-cols-2">
            <%!-- Key/Value is a text+password pair, which Chrome reads as a
                 login form: without these it offers to fill the signed-in
                 user's own email and password into a company secret. --%>
            <.input
              field={@form[:key]}
              label="Key"
              placeholder="API_KEY, DATABASE_URL, etc."
              disabled={@form_mode in [:edit, :rotate]}
              autocomplete="off"
              required
            />

            <div class="ui-advanced-only" data-testid="secret-scope-field">
              <.select
                name={@form[:scope].name}
                label="Scope"
                options={[
                  {"Company", "company"},
                  {"Instance", "instance"},
                  {"Agent", "agent"},
                  {"Project", "project"}
                ]}
                value={@form[:scope].value}
                required
              />
            </div>

            <div
              :if={@form[:scope].value in ["agent", "project"]}
              data-testid="secret-scope-id-field"
              class="ui-advanced-only"
            >
              <.input
                field={@form[:scope_id]}
                label="Scope ID"
                placeholder="Agent or Project ID"
              />
            </div>

            <.input
              :if={@form_mode != :edit}
              field={@form[:value]}
              label={if @form_mode == :rotate, do: "New Value", else: "Value"}
              type="password"
              placeholder="Secret value"
              autocomplete="new-password"
              required={@form_mode in [:create, :rotate]}
            />

            <div class="md:col-span-2">
              <.input
                field={@form[:description]}
                label="Description"
                placeholder="Optional description of what this secret is for"
              />
            </div>
          </div>

          <div class="flex items-center justify-end gap-3 mt-4">
            <button
              type="button"
              phx-click={@on_cancel}
              class="rounded-lg border border-border bg-surface px-4 py-2 text-sm font-510 text-text-secondary transition-colors hover:bg-surface-hover hover:text-text-primary"
            >
              Cancel
            </button>
            <button
              type="submit"
              class="cta-glow inline-flex items-center gap-2 rounded-lg bg-primary px-4 py-2 text-sm font-510 text-white transition-colors hover:bg-primary-hover"
            >
              <.icon name="hero-shield-check-mini" class="h-4 w-4" /> {submit_label(@form_mode)}
            </button>
          </div>
        </.form>
      </div>
    </section>
    """
  end

  defp runtime_hint(%{"key" => "ANTHROPIC_API_KEY"}) do
    %{
      title: "Runtime credential setup",
      summary:
        "ANTHROPIC_API_KEY can supply Claude-compatible wrappers and compatible gateway profiles. For DashScope direct chat, DASHSCOPE_API_KEY is the clearest primary key, but this alias is still accepted by preflight.",
      profile: "Claude-compatible / Qwen gateway",
      save_effect:
        "Runtime preflight can use this credential for Claude-compatible commands or compatible chat gateways.",
      next_step:
        "Verify the CEO agent profile, model, and endpoint before launching the first turn.",
      items: [
        %{label: "Credential key", value: "ANTHROPIC_API_KEY"},
        %{label: "Accepted by", value: "Claude Code wrappers; compatible chat gateways"},
        %{
          label: "Qwen profile",
          value: "OpenAI Chat Qwen DashScope Flash / Plus / Intl"
        },
        %{
          label: "Qwen models",
          value: "qwen3.6-flash for cheap smoke; qwen3.7-plus for stronger planning"
        }
      ]
    }
  end

  defp runtime_hint(%{"key" => "DASHSCOPE_API_KEY"}) do
    %{
      title: "DashScope Qwen runtime setup",
      summary:
        "This secret unlocks DashScope compatible-mode chat completions for OpenAI Chat agents, including the CEO first-turn flow.",
      profile: "OpenAI Chat Qwen DashScope Flash / Plus / Intl",
      save_effect:
        "Runtime preflight marks DashScope Qwen profiles ready without exposing the token.",
      next_step:
        "Use qwen3.6-flash for low-cost smoke runs or qwen3.7-plus for stronger CEO planning.",
      items: [
        %{label: "Credential key", value: "DASHSCOPE_API_KEY"},
        %{label: "Cheap smoke model", value: "qwen3.6-flash"},
        %{label: "Planning model", value: "qwen3.7-plus"},
        %{
          label: "DashScope endpoint",
          value: "https://dashscope.aliyuncs.com/compatible-mode/v1"
        },
        %{
          label: "DashScope Intl endpoint",
          value: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"
        }
      ]
    }
  end

  defp runtime_hint(%{"key" => "LLMOTIONS_API_KEY"}) do
    %{
      title: "LLMotions runtime setup",
      summary:
        "This secret unlocks LLMotions OpenAI-compatible chat completions for CEO and CTO smoke runs.",
      profile: "OpenAI Chat LLMotions Gemma / Gemini Flash",
      save_effect: "Runtime preflight marks LLMotions profiles ready without exposing the token.",
      next_step:
        "Use gemma-4-31b for the first governance smoke, then compare gemini-3.5-flash-low or gemini-3.5-flash on the same scenario.",
      items: [
        %{label: "Credential key", value: "LLMOTIONS_API_KEY"},
        %{label: "Smoke model", value: "gemma-4-31b"},
        %{label: "Alternate models", value: "gemini-3.5-flash-low, gemini-3.5-flash"},
        %{label: "Endpoint", value: "https://cli.llmotions.com/v1"}
      ]
    }
  end

  defp runtime_hint(%{"key" => key}) when key in ["OPENAI_API_KEY", "CODEX_API_KEY"] do
    %{
      title: "Runtime credential setup",
      summary:
        "This secret unlocks Codex runtime execution and OpenAI-compatible hosted agents when their profiles use #{key}.",
      profile: "Codex / OpenAI-compatible runtime",
      save_effect:
        "Codex and compatible runtime preflight can resolve this key from company secrets.",
      next_step: "Check the target agent model and adapter before dispatching repo work.",
      items: [
        %{label: "Credential key", value: key},
        %{label: "Used by", value: "Codex agents and compatible chat providers"}
      ]
    }
  end

  defp runtime_hint(%{"key" => "AGRENTING_API_KEY"}) do
    %{
      title: "Runtime credential setup",
      summary: "This secret unlocks remote Agrenting agents and marketplace hires.",
      profile: "Agrenting remote runtime",
      save_effect: "Remote hire preflight can verify marketplace credentials before assignment.",
      next_step: "Configure remote agent DID, capability, and max price on the agent profile.",
      items: [%{label: "Credential key", value: "AGRENTING_API_KEY"}]
    }
  end

  defp runtime_hint(_prefill), do: nil

  defp form_title(:rotate), do: "Rotate encrypted secret"
  defp form_title(:edit), do: "Edit secret metadata"
  defp form_title(_), do: "Store encrypted runtime secret"

  defp submit_label(:create), do: "Create Secret"
  defp submit_label(:rotate), do: "Rotate Secret"
  defp submit_label(_), do: "Save Secret"
end
