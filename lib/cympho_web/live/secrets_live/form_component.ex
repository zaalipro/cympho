defmodule CymphoWeb.SecretsLive.FormComponent do
  use CymphoWeb, :live_component
  alias Cympho.Secrets
  alias Cympho.Secrets.Secret
  alias CymphoWeb.UserAuth

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
      |> assign(:on_cancel, Map.get(assigns, :on_cancel))
      |> assign(:return_to, return_to)
      |> assign(:runtime_hint, runtime_hint(prefill))
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
    company_id = socket.assigns.company_id
    secret_params = Map.put(secret_params, "company_id", company_id)

    result =
      case socket.assigns.form_mode do
        :create ->
          Secrets.create_secret(secret_params)

        :edit ->
          Secrets.update_secret(socket.assigns.secret, secret_params)

        :rotate ->
          case secret_params["value"] || secret_params[:value] do
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

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :secret))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mb-6 p-4 bg-subtle border border-border rounded-lg">
      <div
        :if={@runtime_hint}
        class="mb-4 rounded-lg border border-brand/25 bg-brand/10 px-3 py-3"
      >
        <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
          <div class="min-w-0">
            <p class="text-xs font-590 uppercase tracking-[0.08em] text-brand">
              {@runtime_hint.title}
            </p>
            <p class="mt-1 text-sm text-text-secondary">{@runtime_hint.summary}</p>
          </div>
          <span class="shrink-0 rounded-full border border-border bg-panel px-2.5 py-1 text-xs text-text-secondary">
            {@runtime_hint.profile}
          </span>
        </div>
        <dl class="mt-3 grid gap-2 border-t border-brand/15 pt-3 sm:grid-cols-2">
          <div
            :for={item <- @runtime_hint.items}
            class="rounded-md border border-brand/15 bg-panel/60 px-3 py-2"
          >
            <dt class="text-[10px] font-590 uppercase tracking-[0.1em] text-text-quaternary">
              {item.label}
            </dt>
            <dd class="mt-1 break-words text-xs text-text-secondary">{item.value}</dd>
          </div>
        </dl>
      </div>

      <.form for={@form} phx-target={@myself} phx-change="validate" phx-submit="save" id="secret-form">
        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <.input
            field={@form[:key]}
            label="Key"
            placeholder="API_KEY, DATABASE_URL, etc."
            disabled={@form_mode in [:edit, :rotate]}
            required
          />

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

          <div :if={@form[:scope].value in ["agent", "project"]}>
            <.input
              field={@form[:scope_id]}
              label="Scope ID"
              placeholder="Agent or Project ID"
            />
          </div>

          <.input
            field={@form[:value]}
            label={if @form_mode == :rotate, do: "New Value", else: "Value"}
            type="password"
            placeholder="Secret value"
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
            class="px-4 py-2 bg-surface hover:bg-surface-hover text-text-secondary rounded-lg text-sm font-medium transition-colors"
          >
            Cancel
          </button>
          <button
            type="submit"
            class="px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded-lg text-sm font-medium transition-colors"
          >
            {submit_label(@form_mode)}
          </button>
        </div>
      </.form>
    </div>
    """
  end

  defp runtime_hint(%{"key" => "ANTHROPIC_API_KEY"}) do
    %{
      title: "Runtime credential setup",
      summary:
        "This secret can unlock compatible chat-completions execution. Pair it with the OpenAI Chat Qwen DashScope profile for the CEO runtime.",
      profile: "OpenAI Chat Qwen DashScope",
      items: [
        %{label: "Model", value: "qwen3.7-plus"},
        %{
          label: "Chat endpoint",
          value: "https://dashscope.aliyuncs.com/compatible-mode/v1"
        }
      ]
    }
  end

  defp runtime_hint(%{"key" => "DASHSCOPE_API_KEY"}) do
    %{
      title: "Runtime credential setup",
      summary:
        "This secret unlocks DashScope compatible-mode chat completions for OpenAI Chat agents.",
      profile: "OpenAI Chat Qwen DashScope",
      items: [
        %{label: "Model", value: "qwen3.7-plus"},
        %{
          label: "Chat endpoint",
          value: "https://dashscope.aliyuncs.com/compatible-mode/v1"
        }
      ]
    }
  end

  defp runtime_hint(%{"key" => key}) when key in ["OPENAI_API_KEY", "CODEX_API_KEY"] do
    %{
      title: "Runtime credential setup",
      summary: "This secret unlocks Codex runtime execution for agents using Codex profiles.",
      profile: "Codex runtime",
      items: [%{label: "Credential key", value: key}]
    }
  end

  defp runtime_hint(%{"key" => "AGRENTING_API_KEY"}) do
    %{
      title: "Runtime credential setup",
      summary: "This secret unlocks remote Agrenting agents and marketplace hires.",
      profile: "Agrenting remote runtime",
      items: [%{label: "Credential key", value: "AGRENTING_API_KEY"}]
    }
  end

  defp runtime_hint(_prefill), do: nil

  defp submit_label(:create), do: "Create Secret"
  defp submit_label(:rotate), do: "Rotate Secret"
  defp submit_label(_), do: "Save Secret"
end
