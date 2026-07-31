defmodule CymphoWeb.Components.CompanyRail do
  use Phoenix.Component

  alias Cympho.Orchestrator.Dispatcher

  use Phoenix.VerifiedRoutes,
    endpoint: CymphoWeb.Endpoint,
    router: CymphoWeb.Router

  attr :company, :map, default: nil
  attr :current_path, :string, default: "/"
  attr :runtime_controls_allowed, :boolean, default: false
  attr :rest, :global

  def company_rail(assigns) do
    ~H"""
    <div class="flex h-14 items-center gap-1.5 border-b border-hairline px-2.5" {@rest}>
      <button
        type="button"
        class="flex min-w-0 flex-1 items-center gap-2 rounded-lg px-2 py-1.5 transition-colors hover:bg-surface-hover"
        onclick="window.openCompanySwitcher && window.openCompanySwitcher()"
      >
        <CymphoWeb.Components.spark class="h-4 w-4 text-brand shrink-0" />
        <.company_display company={@company} />
        <svg
          class="w-4 h-4 text-text-quaternary ml-auto"
          fill="none"
          stroke="currentColor"
          viewBox="0 0 24 24"
        >
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7" />
        </svg>
      </button>
      <.runtime_control_menu
        :if={@runtime_controls_allowed && @company}
        company={@company}
        current_path={@current_path}
      />
    </div>
    """
  end

  attr :company, :map, required: true
  attr :current_path, :string, required: true
  attr :class, :any, default: nil

  def runtime_control_menu(assigns) do
    assigns =
      assigns
      |> assign(:status_label, runtime_status_label(assigns.company))
      |> assign(:status_class, runtime_status_class(assigns.company))

    ~H"""
    <details class={["cympho-menu relative shrink-0", @class]} data-testid="runtime-controls">
      <summary
        class="relative flex h-9 w-9 cursor-pointer list-none items-center justify-center rounded-lg border border-border bg-surface-2 text-text-secondary transition-colors hover:bg-surface-hover hover:text-text-primary focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand/40"
        aria-label={"Runtime: #{@status_label}"}
        title={"Runtime: #{@status_label}"}
        data-testid="runtime-status-trigger"
      >
        <span class="hero-bolt-mini h-4 w-4"></span>
        <span class={[
          "absolute right-1.5 top-1.5 h-1.5 w-1.5 rounded-full ring-2 ring-surface-2",
          @status_class
        ]}>
        </span>
      </summary>

      <div class="cympho-menu-panel absolute right-0 top-full z-[70] mt-2 w-60 rounded-xl border border-hairline bg-surface-2 p-2 shadow-dialog">
        <div class="mb-2 flex items-center justify-between gap-3 px-2 py-1">
          <div class="min-w-0">
            <p class="text-xs font-590 text-text-primary">Runtime</p>
            <p class="truncate text-[11px] text-text-quaternary">{@company.name}</p>
          </div>
          <span class="rounded-full border border-border bg-surface-1 px-2 py-0.5 text-[10px] font-590 text-text-secondary">
            {@status_label}
          </span>
        </div>

        <div class="grid grid-cols-2 gap-1.5">
          <.runtime_button
            :if={!company_paused?(@company) && !company_low_power?(@company)}
            action={~p"/runtime-control/low-power"}
            icon="hero-moon-mini"
            label="Low power"
            current_path={@current_path}
            confirm="Switch to low power? Only urgent work keeps running."
          />
          <.runtime_button
            :if={!company_paused?(@company) && company_low_power?(@company)}
            action={~p"/runtime-control/resume"}
            icon="hero-bolt-mini"
            label="Full power"
            current_path={@current_path}
          />
          <.runtime_button
            :if={!company_paused?(@company)}
            action={~p"/runtime-control/pause"}
            icon="hero-pause-mini"
            label="Pause"
            current_path={@current_path}
            confirm="Pause your agents? Queued work is saved for later."
          />
          <.runtime_button
            :if={company_paused?(@company)}
            action={~p"/runtime-control/resume"}
            icon="hero-play-mini"
            label="Resume"
            current_path={@current_path}
          />
          <.runtime_button
            action={~p"/runtime-control/stop"}
            icon="hero-stop-mini"
            label="Stop"
            tone="danger"
            current_path={@current_path}
            confirm="Stop your agents and clear the queue?"
          />
          <.link
            navigate={~p"/operations"}
            onclick="this.closest('details').removeAttribute('open')"
            data-runtime-menu-close
            class="inline-flex h-9 items-center justify-center gap-1.5 rounded-lg border border-border bg-surface-1 px-2 text-xs font-590 text-text-secondary transition-colors hover:bg-surface-hover hover:text-text-primary"
          >
            <span class="hero-command-line-mini h-3.5 w-3.5"></span> Operations
          </.link>
        </div>
      </div>
    </details>
    """
  end

  attr :action, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :tone, :string, default: "neutral"
  attr :current_path, :string, required: true
  attr :confirm, :string, default: nil

  defp runtime_button(assigns) do
    ~H"""
    <form method="post" action={@action}>
      <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
      <input type="hidden" name="return_to" value={@current_path} />
      <button
        type="submit"
        data-confirm={@confirm}
        class={[
          "inline-flex h-9 w-full items-center justify-center gap-1.5 rounded-lg border px-2 text-xs font-590 transition-colors",
          @tone == "danger" &&
            "border-red-500/25 bg-red-500/10 text-red-300 hover:bg-red-500/15 hover:text-red-200",
          @tone != "danger" &&
            "border-border bg-surface-1 text-text-secondary hover:bg-surface-hover hover:text-text-primary"
        ]}
      >
        <span class={[@icon, "h-3.5 w-3.5"]}></span>
        {@label}
      </button>
    </form>
    """
  end

  attr :company, :map, default: nil

  def company_display(%{company: nil} = assigns) do
    ~H"""
    <span class="text-sm font-590 text-text-primary">Cympho</span>
    """
  end

  def company_display(%{company: company} = assigns) do
    assigns = assign(assigns, :company, company)

    ~H"""
    <%!-- min-w-0 on the flex wrapper and the shrink guards on the badge are what
         make `truncate` actually work: a flex child defaults to min-width:auto,
         so without them a long company name pushes the runtime control off the
         rail instead of ellipsing. --%>
    <div class="flex min-w-0 items-center gap-3">
      <div :if={@company.logo_url} class="h-6 w-6 shrink-0 overflow-hidden rounded-lg">
        <img src={@company.logo_url} alt={@company.name} class="w-full h-full object-cover" />
      </div>
      <div
        :if={!@company.logo_url}
        class="flex h-6 w-6 shrink-0 items-center justify-center rounded-lg bg-brand/12"
      >
        <span class="text-[11px] font-590 text-brand">{company_initials(@company.name)}</span>
      </div>
      <span
        class="hidden min-w-0 truncate text-sm font-590 text-text-primary md:inline"
        title={@company.name}
      >
        {@company.name}
      </span>
    </div>
    """
  end

  defp company_initials(name) when is_binary(name) do
    name
    |> String.split(~r/\s+/)
    |> Enum.take(2)
    |> Enum.map(&String.first/1)
    |> Enum.join()
    |> String.upcase()
  end

  defp company_initials(_), do: "?"

  defp company_paused?(%{status: "paused"}), do: true
  defp company_paused?(_company), do: false

  defp company_low_power?(%{governance_config: %{"runtime_mode" => "low_power"}}), do: true
  defp company_low_power?(_company), do: false

  defp runtime_status_label(company) do
    cond do
      not Dispatcher.enabled?() and company_paused?(company) -> "Review mode · paused"
      not Dispatcher.enabled?() and company_low_power?(company) -> "Review mode · low power"
      not Dispatcher.enabled?() -> "Review mode"
      company_paused?(company) -> "Paused"
      company_low_power?(company) -> "Low power"
      true -> "Full power"
    end
  end

  defp runtime_status_class(company) do
    cond do
      company_paused?(company) -> "bg-amber-400"
      company_low_power?(company) -> "bg-sky-400"
      not Dispatcher.enabled?() -> "bg-gray-400"
      true -> "bg-emerald-400"
    end
  end
end
