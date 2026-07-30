defmodule CymphoWeb.CompanyExportLive do
  use CymphoWeb, :live_view

  alias Cympho.Companies

  @impl true
  def mount(params, _session, socket) do
    company_id = Map.get(params, "company_id") || Map.fetch!(params, "id")
    user_id = socket.assigns.current_user.id

    if Companies.admin?(user_id, company_id) or Companies.is_board_member?(user_id, company_id) do
      company = Companies.get_company!(company_id)

      {:ok,
       socket
       |> assign(:page_title, "Export #{company.name}")
       |> assign(:company, company)
       |> assign(:secret_manifest, Companies.export_secret_manifest(company_id))
       |> assign(:export_data, nil)
       |> assign(:loading, false)
       |> assign(:download_ready, false)}
    else
      {:ok,
       socket
       |> put_flash(:error, "Company not found or you cannot export it.")
       |> redirect(to: ~p"/companies")}
    end
  end

  @impl true
  def handle_event("generate_export", _params, socket) do
    send(self(), :do_export)

    {:noreply,
     socket
     |> assign(:loading, true)
     |> assign(:export_data, nil)
     |> assign(:download_ready, false)}
  end

  @impl true
  def handle_event("download", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info(:do_export, socket) do
    export_data = Companies.export_company(socket.assigns.company.id)

    {:noreply,
     socket
     |> assign(:loading, false)
     |> assign(:export_data, export_data)
     |> assign(:download_ready, true)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="ember-aurora px-4 py-6 sm:px-6 lg:px-8">
      <div class="relative z-[1] mx-auto max-w-7xl space-y-6">
        <.header>
          <div class="min-w-0">
            <span class="ember-eyebrow">Portability</span>
            <h1 class="ember-ink mt-4 font-serif text-[clamp(28px,4vw,42px)] font-510 leading-[1.08] tracking-[-0.02em]">
              Export {@company.name}
            </h1>
            <p class="mt-2 max-w-2xl text-[15px] leading-6 text-text-tertiary">
              Move this operating company into another Cympho instance.
            </p>
          </div>
          <:actions>
            <.app_link
              navigate={~p"/companies/#{@company}"}
              class="rounded-lg border border-border bg-button px-4 py-2 text-sm font-510 text-text-secondary transition-colors hover:bg-button-hover hover:text-text-primary"
            >
              Back to Company
            </.app_link>
          </:actions>
        </.header>

        <section
          data-testid="company-export-command"
          class="ember-glass overflow-hidden"
        >
          <div class="grid gap-0 lg:grid-cols-[minmax(0,1.35fr)_minmax(300px,0.65fr)]">
            <div class="p-6 lg:p-8">
              <div class="mb-4 inline-flex items-center gap-2 rounded-full border border-brand/20 bg-brand/10 px-3 py-1 text-xs font-510 text-brand">
                <.icon name="hero-arrow-down-tray-mini" class="h-4 w-4" /> Company portability
              </div>
              <h2 class="font-serif text-2xl font-510 text-text-primary">
                Generate a portable operating export
              </h2>
              <p class="mt-3 max-w-2xl text-sm leading-6 text-text-secondary">
                Move the company graph, work queues, agents, goals, labels, memberships, and issue history into another Cympho instance. Secret values stay out of the file; only a restore checklist is included.
              </p>

              <div class="mt-6 flex flex-wrap items-center gap-3">
                <button
                  :if={!@loading}
                  phx-click="generate_export"
                  class="inline-flex items-center gap-2 cta-glow rounded-button bg-brand px-5 py-3 text-sm font-510 text-on-primary transition-colors hover:bg-accent"
                >
                  <.icon name="hero-arrow-path-mini" class="h-4 w-4" />
                  {if @download_ready, do: "Regenerate export", else: "Generate export"}
                </button>

                <div
                  :if={@loading}
                  class="inline-flex items-center gap-2 rounded-button border border-border bg-subtle px-5 py-3 text-sm font-510 text-text-secondary"
                >
                  <.icon name="hero-arrow-path-mini" class="h-4 w-4 animate-spin" />
                  Generating export...
                </div>

                <a
                  :if={@download_ready && @export_data}
                  download={"#{@company.slug}-export-#{Date.utc_today()}.json"}
                  href={download_href(@export_data)}
                  class="inline-flex items-center gap-2 rounded-button border border-emerald-500/25 bg-emerald-500/10 px-5 py-3 text-sm font-510 text-emerald-300 transition-colors hover:bg-emerald-500/15"
                >
                  <.icon name="hero-arrow-down-tray-mini" class="h-4 w-4" /> Download JSON
                </a>
              </div>

              <div :if={@download_ready && @export_data} class="mt-4 text-xs text-text-tertiary">
                Exported {@export_data.exported_at} / Version {@export_data.version}
              </div>
            </div>

            <div class="border-t border-border bg-subtle/60 p-6 lg:border-l lg:border-t-0 lg:p-8">
              <div class="text-xs font-510 uppercase tracking-wider text-text-tertiary">
                Safety posture
              </div>
              <div class="mt-4 space-y-4">
                <div class="flex items-start gap-3">
                  <span class="mt-0.5 rounded-md bg-emerald-500/10 p-2 text-emerald-300">
                    <.icon name="hero-shield-check-mini" class="h-4 w-4" />
                  </span>
                  <div>
                    <div class="text-sm font-510 text-text-primary">Secret values scrubbed</div>
                    <p class="mt-1 text-xs leading-5 text-text-secondary">
                      Encrypted payloads, hashes, and provider keys are not serialized.
                    </p>
                  </div>
                </div>
                <div class="flex items-start gap-3">
                  <span class="mt-0.5 rounded-md bg-amber-500/10 p-2 text-amber-200">
                    <.icon name="hero-key-mini" class="h-4 w-4" />
                  </span>
                  <div>
                    <div class="text-sm font-510 text-text-primary">
                      {Enum.count(active_secret_manifest(@export_data, @secret_manifest))} restore entries
                    </div>
                    <p class="mt-1 text-xs leading-5 text-text-secondary">
                      Operators get the keys and scopes they must re-enter after import.
                    </p>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </section>

        <section
          :if={@download_ready && @export_data}
          class="rounded-xl border border-border bg-surface p-6 lg:p-8"
        >
          <div class="mb-5 flex flex-col gap-2 sm:flex-row sm:items-end sm:justify-between">
            <div>
              <h3 class="font-serif text-xl font-510 text-text-primary">Export inventory</h3>
              <p class="mt-1 text-sm text-text-secondary">
                This is the portable company footprint that will be recreated on import.
              </p>
            </div>
          </div>

          <div class="grid grid-cols-2 gap-3 md:grid-cols-4 lg:grid-cols-6">
            <div
              :for={metric <- export_metrics(@export_data)}
              class="ember-stat rounded-lg border border-border bg-subtle p-4"
            >
              <div class="font-serif text-2xl font-510 tabular-nums text-text-primary">
                {metric.value}
              </div>
              <div class="mt-1 text-xs font-510 uppercase tracking-wider text-text-tertiary">
                {metric.label}
              </div>
            </div>
          </div>
        </section>

        <section
          data-testid="secret-restore-manifest"
          class="rounded-xl border border-border bg-surface p-6 lg:p-8"
        >
          <div class="flex flex-col gap-2 sm:flex-row sm:items-end sm:justify-between">
            <div>
              <h3 class="font-serif text-xl font-510 text-text-primary">Secret restore checklist</h3>
              <p class="mt-1 text-sm text-text-secondary">
                The export records secret names and scopes only. Values must be supplied again in the destination company.
              </p>
            </div>
            <span class="inline-flex w-fit items-center gap-2 rounded-full border border-amber-500/25 bg-amber-500/10 px-3 py-1 text-xs font-510 text-amber-200">
              <.icon name="hero-key-mini" class="h-4 w-4" />
              {Enum.count(active_secret_manifest(@export_data, @secret_manifest))} keys
            </span>
          </div>

          <div
            :if={active_secret_manifest(@export_data, @secret_manifest) == []}
            class="mt-5 rounded-lg border border-border bg-subtle p-5 text-sm text-text-secondary"
          >
            No active secrets are recorded for this company.
          </div>

          <div
            :if={active_secret_manifest(@export_data, @secret_manifest) != []}
            class="mt-5 overflow-hidden rounded-lg border border-border"
          >
            <div
              :for={secret <- active_secret_manifest(@export_data, @secret_manifest)}
              class="flex flex-col gap-3 border-b border-border bg-subtle/60 p-4 last:border-b-0 sm:flex-row sm:items-center sm:justify-between"
            >
              <div class="min-w-0">
                <div class="truncate text-sm font-510 text-text-primary">{secret.key}</div>
                <div class="mt-1 text-xs text-text-secondary">
                  {format_scope(secret.scope)} scope{if secret.scope_id,
                    do: " / scoped target preserved",
                    else: ""}
                </div>
              </div>
              <div class="text-left text-xs text-text-tertiary sm:max-w-md sm:text-right">
                {secret.description || "No description provided"}
              </div>
            </div>
          </div>
        </section>

        <div class="rounded-xl border border-amber-500/20 bg-amber-500/10 p-4 text-sm text-amber-200">
          <strong>Storage note:</strong>
          The file still contains company work content, comments, and operating metadata. Store it with the same care as a production backup.
        </div>
      </div>
    </div>
    """
  end

  defp download_href(export_data) do
    "data:application/json;charset=utf-8,#{URI.encode(Jason.encode!(export_data))}"
  end

  defp active_secret_manifest(%{secret_manifest: manifest}, _fallback) when is_list(manifest),
    do: manifest

  defp active_secret_manifest(_export_data, manifest) when is_list(manifest), do: manifest
  defp active_secret_manifest(_export_data, _manifest), do: []

  defp export_metrics(export_data) do
    [
      %{label: "Projects", value: export_count(export_data, :projects)},
      %{label: "Agents", value: export_count(export_data, :agents)},
      %{label: "Issues", value: export_count(export_data, :issues)},
      %{label: "Goals", value: export_count(export_data, :goals)},
      %{label: "Labels", value: export_count(export_data, :labels)},
      %{label: "Members", value: export_count(export_data, :memberships)}
    ]
  end

  defp export_count(export_data, key) when is_map(export_data) do
    export_data
    |> Map.get(key, [])
    |> Enum.count()
  end

  defp export_count(_export_data, _key), do: 0

  defp format_scope(scope) when is_atom(scope), do: scope |> Atom.to_string() |> format_scope()

  defp format_scope(scope) when is_binary(scope) do
    scope
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp format_scope(_scope), do: "Company"
end
