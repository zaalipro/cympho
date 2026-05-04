defmodule CymphoWeb.CompanyExportLive do
  use CymphoWeb, :live_view

  alias Cympho.Companies

  @impl true
  def mount(%{"company_id" => company_id}, _session, socket) do
    company = Companies.get_company!(company_id)

    {:ok,
     socket
     |> assign(:page_title, "Export #{company.name}")
     |> assign(:company, company)
     |> assign(:export_data, nil)
     |> assign(:loading, false)
     |> assign(:download_ready, false)}
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
    <div class="p-6 lg:p-8 max-w-6xl mx-auto">
      <.header title={"Export #{@company.name}"}>
        <:actions>
          <.app_link
            navigate={~p"/companies/#{@company}"}
            class="text-text-secondary hover:text-text-primary text-sm"
          >
            Back to Company
          </.app_link>
        </:actions>
      </.header>

      <div class="space-y-6">
        <div class="bg-surface border border-border rounded-xl p-6">
          <h3 class="font-serif text-lg font-510 text-text-primary mb-4">Export Your Company Data</h3>
          <p class="text-text-secondary text-sm mb-6">
            Export all company data including projects, agents, issues, goals, and labels. The exported file can be used to import this data into another Cympho instance or for backup purposes.
          </p>

          <div :if={@loading} class="flex items-center gap-3 text-text-secondary">
            <svg
              class="animate-spin h-5 w-5"
              xmlns="http://www.w3.org/2000/svg"
              fill="none"
              viewBox="0 0 24 24"
            >
              <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4">
              </circle>
              <path
                class="opacity-75"
                fill="currentColor"
                d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
              >
              </path>
            </svg>
            Generating export...
          </div>

          <button
            :if={!@loading && !@download_ready}
            phx-click="generate_export"
            class="bg-brand hover:bg-accent text-white font-510 text-sm px-6 py-3 rounded-lg transition-colors inline-flex items-center gap-2"
          >
            <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M4 16v1a3 3 0 003 3h10a3 3 0 003-3v-1m-4-8l-4-4m0 0L8 8m4-4v12"
              />
            </svg>
            Generate Export
          </button>
        </div>

        <div
          :if={@download_ready && @export_data}
          class="bg-surface border border-border rounded-xl p-6"
        >
          <h3 class="font-serif text-lg font-510 text-text-primary mb-4">Export Ready!</h3>

          <div class="grid grid-cols-2 md:grid-cols-4 gap-4 mb-6">
            <div class="bg-subtle border border-border rounded-lg p-4 text-center">
              <div class="text-2xl font-510 text-brand">{Enum.count(@export_data.projects)}</div>
              <div class="text-xs text-text-secondary mt-1">Projects</div>
            </div>
            <div class="bg-subtle border border-border rounded-lg p-4 text-center">
              <div class="text-2xl font-510 text-brand">{Enum.count(@export_data.agents)}</div>
              <div class="text-xs text-text-secondary mt-1">Agents</div>
            </div>
            <div class="bg-subtle border border-border rounded-lg p-4 text-center">
              <div class="text-2xl font-510 text-brand">{Enum.count(@export_data.issues)}</div>
              <div class="text-xs text-text-secondary mt-1">Issues</div>
            </div>
            <div class="bg-subtle border border-border rounded-lg p-4 text-center">
              <div class="text-2xl font-510 text-brand">{Enum.count(@export_data.goals)}</div>
              <div class="text-xs text-text-secondary mt-1">Goals</div>
            </div>
          </div>

          <a
            download={"#{@company.slug}-export-#{Date.utc_today()}.json"}
            href={"data:application/json;charset=utf-8,#{URI.encode(Jason.encode!(@export_data))}"}
            class="bg-success hover:bg-success/80 text-white font-510 text-sm px-6 py-3 rounded-lg transition-colors inline-flex items-center gap-2"
          >
            <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M4 16v1a3 3 0 003 3h10a3 3 0 003-3v-1m-4-8l-4-4m0 0L8 8m4-4v12"
              />
            </svg>
            Download Export
          </a>

          <div class="mt-4 text-xs text-text-tertiary">
            Exported on {@export_data.exported_at} • Version {@export_data.version}
          </div>
        </div>

        <div class="bg-yellow-500/10 border border-yellow-500/20 text-yellow-400 rounded-xl p-4 text-sm">
          <strong>Note:</strong>
          This export contains sensitive data. Store it securely and do not share it with unauthorized parties.
        </div>
      </div>
    </div>
    """
  end
end
