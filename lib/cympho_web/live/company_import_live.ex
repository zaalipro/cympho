defmodule CymphoWeb.CompanyImportLive do
  use CymphoWeb, :live_view

  @inventory_keys ~w(projects agents issues goals users memberships comments labels package_records planned_writes)a
  @secret_keys ~w(key scope scope_id description restore_status)a

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Import Company")
     |> reset_transfer_assigns()}
  end

  @impl true
  def handle_event(
        "transfer_declared",
        %{"transfer_id" => transfer_id, "slug_strategy" => strategy},
        socket
      )
      when strategy in ["suffix", "fail"] do
    case Ecto.UUID.cast(transfer_id) do
      {:ok, _id} ->
        {:noreply,
         socket
         |> assign(:transfer_id, transfer_id)
         |> assign(:slug_strategy, if(strategy == "fail", do: :fail, else: :suffix))}

      :error ->
        {:noreply, transfer_error(socket, "The upload returned an invalid transfer ID.")}
    end
  end

  def handle_event("transfer_declared", %{"transfer_id" => transfer_id}, socket) do
    case Ecto.UUID.cast(transfer_id) do
      {:ok, _id} -> {:noreply, assign(socket, :transfer_id, transfer_id)}
      :error -> {:noreply, transfer_error(socket, "The upload returned an invalid transfer ID.")}
    end
  end

  def handle_event(
        "transfer_completed",
        %{"transfer_id" => transfer_id, "imported_company_id" => company_id} = payload,
        socket
      ) do
    with {:ok, _transfer_uuid} <- Ecto.UUID.cast(transfer_id),
         {:ok, _company_uuid} <- Ecto.UUID.cast(company_id) do
      secrets =
        payload
        |> payload_field(:secrets_to_restore, [])
        |> normalize_list(@secret_keys, 5_000)

      restore_receipt_available =
        payload_field(payload, :restore_receipt_available, false) == true

      {:noreply,
       socket
       |> assign(:transfer_id, transfer_id)
       |> assign(:importing, false)
       |> assign(:import_result, {
         :ok,
         %{
           company: %{id: company_id},
           secrets_to_restore: secrets,
           restore_receipt_available: restore_receipt_available,
           already_completed: true
         }
       })
       |> assign(:step, :complete)
       |> assign(:progress, nil)}
    else
      _error ->
        {:noreply,
         transfer_error(
           socket,
           "This transfer already completed, but its imported company could not be identified."
         )}
    end
  end

  def handle_event(
        "transfer_previewed",
        %{
          "transfer_id" => transfer_id,
          "slug_strategy" => strategy,
          "preview" => preview
        },
        %{assigns: %{transfer_id: transfer_id, slug_strategy: strategy_atom}} = socket
      )
      when is_map(preview) and strategy in ["suffix", "fail"] do
    expected_strategy = Atom.to_string(strategy_atom)
    preview_plan = normalize_preview(preview)

    if strategy == expected_strategy do
      {:noreply,
       socket
       |> assign(:preview_plan, preview_plan)
       |> assign(:validation_errors, [])
       |> assign(:step, :preview)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("transfer_previewed", _params, socket), do: {:noreply, socket}

  def handle_event("transfer_failed", %{"error" => error}, socket) do
    {:noreply, transfer_error(socket, safe_client_message(error))}
  end

  def handle_event("transfer_preview_failed", %{"error" => error}, socket) do
    step = if is_map(socket.assigns.preview_plan), do: :preview, else: :upload

    {:noreply,
     socket
     |> assign(:importing, false)
     |> assign(:validation_errors, [safe_client_message(error)])
     |> assign(:step, step)}
  end

  def handle_event("transfer_apply_failed", %{"error" => error}, socket) do
    {:noreply,
     socket
     |> assign(:importing, false)
     |> assign(:import_result, {:error, safe_client_message(error)})
     |> assign(:step, :complete)
     |> assign(:progress, nil)}
  end

  def handle_event("transfer_cancelled", _params, socket) do
    {:noreply, reset_transfer_assigns(socket)}
  end

  @impl true
  def handle_event("start_import", _params, socket) do
    cond do
      socket.assigns.importing ->
        {:noreply, socket}

      preview_ready?(socket.assigns.preview_plan) and socket.assigns.validation_errors == [] and
          is_binary(socket.assigns.transfer_id) ->
        {:noreply,
         socket
         |> assign(:importing, true)
         |> assign(:step, :importing)
         |> assign(:progress, "Creating the imported company…")
         |> push_event("company-import:apply", %{
           transfer_id: socket.assigns.transfer_id,
           slug_strategy: Atom.to_string(socket.assigns.slug_strategy)
         })}

      true ->
        {:noreply, put_flash(socket, :error, "Resolve the import preview blockers first.")}
    end
  end

  def handle_event(
        "transfer_applied",
        %{"transfer_id" => transfer_id, "result" => result},
        %{assigns: %{transfer_id: transfer_id}} = socket
      )
      when is_map(result) do
    company =
      result
      |> payload_field(:data, %{})
      |> take_payload([:id, :name, :slug])

    secrets =
      result
      |> payload_field(:secrets_to_restore, [])
      |> normalize_list(@secret_keys, 5_000)

    {:noreply,
     socket
     |> assign(:importing, false)
     |> assign(:import_result, {
       :ok,
       %{company: company, secrets_to_restore: secrets, restore_receipt_available: true}
     })
     |> assign(:step, :complete)
     |> assign(:progress, nil)}
  end

  def handle_event("transfer_applied", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("reset", _params, socket) do
    socket =
      case socket.assigns.transfer_id do
        transfer_id when is_binary(transfer_id) ->
          push_event(socket, "company-import:reset", %{transfer_id: transfer_id})

        _ ->
          socket
      end

    {:noreply, reset_transfer_assigns(socket)}
  end

  defp reset_transfer_assigns(socket) do
    socket
    |> assign(:step, :upload)
    |> assign(:transfer_id, nil)
    |> assign(:preview_plan, nil)
    |> assign(:validation_errors, [])
    |> assign(:slug_strategy, :suffix)
    |> assign(:importing, false)
    |> assign(:import_result, nil)
    |> assign(:progress, nil)
  end

  defp transfer_error(socket, message) do
    socket
    |> assign(:importing, false)
    |> assign(:preview_plan, nil)
    |> assign(:validation_errors, [message])
    |> assign(:step, :upload)
  end

  defp safe_client_message(message) when is_binary(message) do
    message
    |> String.replace(~r/[\r\n\t]+/u, " ")
    |> String.slice(0, 500)
  end

  defp safe_client_message(_message), do: "The transfer could not be completed."

  defp normalize_preview(preview) do
    %{
      ready?: payload_field(preview, :ready?, false) == true,
      version: preview |> payload_field(:version) |> normalize_plan_value(),
      company: preview |> payload_field(:company, %{}) |> take_payload([:name, :source_slug]),
      inventory: preview |> payload_field(:inventory, %{}) |> take_payload(@inventory_keys, 0),
      target: preview |> payload_field(:target, %{}) |> take_payload([:requested_slug, :slug]),
      secret_restore_requirements:
        preview
        |> payload_field(:secret_restore_requirements, [])
        |> normalize_list(@secret_keys, 5_000),
      warnings:
        preview
        |> payload_field(:warnings, [])
        |> normalize_list([:message], 100)
    }
  end

  defp take_payload(value, keys, default \\ nil)

  defp take_payload(value, keys, default) when is_map(value) do
    Map.new(keys, &{&1, value |> payload_field(&1, default) |> normalize_plan_value()})
  end

  defp take_payload(_value, keys, default), do: Map.new(keys, &{&1, default})

  defp normalize_list(value, keys, max_items) when is_list(value) do
    value |> Enum.take(max_items) |> Enum.map(&take_payload(&1, keys))
  end

  defp normalize_list(_value, _keys, _max_items), do: []

  defp payload_field(map, key, default \\ nil)

  defp payload_field(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp payload_field(_map, _key, default), do: default

  defp normalize_plan_value(value) when is_binary(value), do: String.slice(value, 0, 1_000)
  defp normalize_plan_value(value) when is_integer(value), do: value
  defp normalize_plan_value(value) when is_boolean(value), do: value
  defp normalize_plan_value(nil), do: nil
  defp normalize_plan_value(_value), do: nil

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="company-import-transfer"
      phx-hook="CompanyImportTransfer"
      data-base-path="/companies/import/transfers"
      data-transfer-id={@transfer_id}
      class="ember-aurora p-4 sm:p-6 lg:p-8"
    >
      <div class="relative z-[1] mx-auto max-w-6xl">
        <.header>
          <div class="min-w-0">
            <span class="ember-eyebrow">Portability</span>
            <h1 class="ember-ink mt-4 font-serif text-[clamp(28px,4vw,42px)] font-510 leading-[1.08] tracking-[-0.02em]">
              Import Company
            </h1>
            <p class="mt-2 max-w-2xl text-[15px] leading-6 text-text-tertiary">
              Restore a portable company export into this instance.
            </p>
          </div>
          <:actions>
            <.app_link
              navigate={~p"/companies"}
              class="rounded-lg border border-border bg-button px-4 py-2 text-sm font-510 text-text-secondary transition-colors hover:bg-button-hover hover:text-text-primary"
            >
              Back to Companies
            </.app_link>
          </:actions>
        </.header>

        <section
          data-testid="company-import-command"
          class="mb-6 ember-glass overflow-hidden"
        >
          <div class="grid gap-0 lg:grid-cols-[minmax(0,1.35fr)_minmax(300px,0.65fr)]">
            <div class="p-6 lg:p-8">
              <div class="mb-4 inline-flex items-center gap-2 rounded-full border border-brand/20 bg-brand/10 px-3 py-1 text-xs font-510 text-brand">
                <.icon name="hero-arrow-up-tray-mini" class="h-4 w-4" /> Company portability
              </div>
              <h2 class="font-serif text-2xl font-510 text-text-primary">
                {import_command_title(@step, @preview_plan, @import_result)}
              </h2>
              <p class="mt-3 max-w-2xl text-sm leading-6 text-text-secondary">
                {import_command_summary(
                  @step,
                  @import_result,
                  @preview_plan
                )}
              </p>
            </div>

            <div class="border-t border-border bg-subtle/60 p-6 lg:border-l lg:border-t-0 lg:p-8">
              <div class="grid grid-cols-2 gap-3">
                <div
                  :for={
                    metric <-
                      import_command_metrics(
                        @step,
                        @import_result,
                        @preview_plan
                      )
                  }
                  class="min-w-0 overflow-hidden rounded-lg border border-border bg-surface p-4"
                >
                  <div class="truncate text-lg font-510 text-text-primary">{metric.value}</div>
                  <div class="mt-1 text-xs font-510 uppercase tracking-wider text-text-tertiary">
                    {metric.label}
                  </div>
                </div>
              </div>
            </div>
          </div>
        </section>

        {render_step(assigns)}
      </div>
    </div>
    """
  end

  defp render_step(%{step: step} = assigns) when step in [:upload, :uploading] do
    ~H"""
    <div class="space-y-6">
      <div class="rounded-xl border border-border bg-surface p-4 sm:p-6">
        <h3 class="mb-2 font-serif text-lg font-510 text-text-primary">Upload export file</h3>
        <p class="mb-6 max-w-2xl text-sm leading-6 text-text-secondary">
          Choose a Cympho JSON export. Large files upload in verified 4 MiB parts, so an interrupted transfer can continue after you select the same file again.
        </p>

        <fieldset class="mb-6">
          <legend class="text-sm font-510 text-text-primary">
            If the company slug already exists
          </legend>
          <div class="mt-3 flex flex-col gap-3 sm:flex-row sm:gap-6">
            <label class="flex items-center gap-2 text-sm text-text-secondary">
              <input
                data-transfer-strategy
                type="radio"
                name="import_slug_strategy"
                value="suffix"
                checked={@slug_strategy == :suffix}
                class="h-4 w-4 text-brand"
              /> Create a safe <code>-copy</code>
              slug
            </label>
            <label class="flex items-center gap-2 text-sm text-text-secondary">
              <input
                data-transfer-strategy
                type="radio"
                name="import_slug_strategy"
                value="fail"
                checked={@slug_strategy == :fail}
                class="h-4 w-4 text-brand"
              /> Stop without importing
            </label>
          </div>
          <p class="mt-2 text-xs text-text-tertiary">
            Keep the same choice when resuming an interrupted transfer.
          </p>
        </fieldset>

        <div
          id="import-dropzone"
          data-transfer-dropzone
          class="rounded-xl border-2 border-dashed border-border bg-subtle/50 p-8 text-center transition-colors focus-within:border-brand/60"
        >
          <span class="mx-auto mb-4 flex h-12 w-12 items-center justify-center rounded-xl bg-brand/10 text-brand">
            <.icon name="hero-document-arrow-up-mini" class="h-6 w-6" />
          </span>
          <label for="company-import-file" class="text-sm font-510 text-text-primary">
            Choose a company export
          </label>
          <p id="company-import-file-help" class="mt-2 text-xs leading-5 text-text-tertiary">
            JSON only, up to 50 MB. The browser reads one part at a time and never stores an API token.
          </p>
          <input
            id="company-import-file"
            data-transfer-file
            type="file"
            accept=".json,application/json"
            aria-describedby="company-import-file-help company-import-status"
            class="mx-auto mt-5 block max-w-full text-sm text-text-secondary file:mr-4 file:cursor-pointer file:rounded-button file:border-0 file:bg-brand file:px-5 file:py-3 file:text-sm file:font-510 file:text-on-primary hover:file:bg-accent"
          />
        </div>

        <div
          id="company-import-progress"
          data-transfer-progress
          phx-update="ignore"
          class="mt-5 hidden rounded-lg border border-border bg-subtle p-4"
        >
          <div class="flex items-center justify-between gap-4 text-sm">
            <span data-transfer-filename class="min-w-0 truncate font-510 text-text-primary"></span>
            <span data-transfer-percent class="shrink-0 tabular-nums text-text-secondary">0%</span>
          </div>
          <div
            class="mt-3 h-2 overflow-hidden rounded-full bg-surface"
            role="progressbar"
            aria-label="Company import upload"
            aria-valuemin="0"
            aria-valuemax="100"
            aria-valuenow="0"
            data-transfer-progressbar
          >
            <div
              data-transfer-progressfill
              class="h-full w-full origin-left scale-x-0 bg-brand transition-transform"
            >
            </div>
          </div>
          <div class="mt-3 flex items-center justify-between gap-4">
            <p
              id="company-import-status"
              data-transfer-status
              role="status"
              aria-live="polite"
              class="text-xs text-text-secondary"
            >
              Preparing file…
            </p>
            <button
              type="button"
              data-transfer-cancel
              class="rounded-lg border border-border px-3 py-1.5 text-xs font-510 text-text-secondary hover:text-text-primary"
            >
              Pause
            </button>
          </div>
        </div>

        <div
          :if={@validation_errors != []}
          data-testid="company-import-errors"
          role="alert"
          class="mt-6 rounded-xl border border-red-500/20 bg-red-500/10 p-4 text-red-400"
        >
          <h4 class="mb-2 font-510">Import could not continue</h4>
          <ul class="list-disc space-y-1 pl-5 text-sm">
            <li :for={error <- @validation_errors}>{error}</li>
          </ul>
        </div>
      </div>

      <div class="rounded-xl border border-blue-500/20 bg-blue-500/10 p-4 text-sm text-blue-400">
        <strong>Safe to retry:</strong>
        Re-selecting the same file declares the same content manifest and uploads only missing parts.
      </div>
    </div>
    """
  end

  defp render_step(%{step: :preview, preview_plan: %{} = _preview_plan} = assigns) do
    ~H"""
    <div class="space-y-6">
      <div
        data-testid="company-import-preview"
        class="rounded-xl border border-border bg-surface p-4 sm:p-6"
      >
        <h3 class="font-serif text-lg font-510 text-text-primary mb-4">Preview Import</h3>

        <div
          :if={@validation_errors != []}
          role="alert"
          class="mb-6 rounded-lg border border-red-500/20 bg-red-500/10 p-4 text-sm text-red-400"
        >
          <p :for={error <- @validation_errors}>{error}</p>
        </div>

        <div class="bg-subtle border border-border rounded-lg p-6 mb-6">
          <div class="flex items-center gap-4 mb-4">
            <div class="w-16 h-16 bg-brand/10 rounded-lg flex items-center justify-center">
              <svg class="w-8 h-8 text-brand" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M19 21V5a2 2 0 00-2-2H7a2 2 0 00-2 2v16m14 0h2m-2 0h-5m-9 0H3m2 0h5M9 7h1m-1 4h1m4-4h1m-1 4h1m-5 10v-5a1 1 0 011-1h2a1 1 0 011 1v5m-4 0h4"
                />
              </svg>
            </div>
            <div class="min-w-0">
              <h4 class="break-words text-xl font-510 text-text-primary">
                {@preview_plan.company.name}
              </h4>
              <div class="text-text-secondary text-sm">
                <code class="break-all rounded bg-black/20 px-2 py-1">
                  {@preview_plan.company.source_slug}
                </code>
                <span class="ml-2">Version {@preview_plan.version}</span>
              </div>
            </div>
          </div>

          <div class="grid grid-cols-2 gap-4 md:grid-cols-4">
            <div class="text-center">
              <div class="text-2xl font-510 text-brand">
                {@preview_plan.inventory.projects}
              </div>
              <div class="text-xs text-text-secondary mt-1">Projects</div>
            </div>
            <div class="text-center">
              <div class="text-2xl font-510 text-brand">
                {@preview_plan.inventory.agents}
              </div>
              <div class="text-xs text-text-secondary mt-1">Agents</div>
            </div>
            <div class="text-center">
              <div class="text-2xl font-510 text-brand">
                {@preview_plan.inventory.issues}
              </div>
              <div class="text-xs text-text-secondary mt-1">Issues</div>
            </div>
            <div class="text-center">
              <div class="text-2xl font-510 text-brand">
                {@preview_plan.inventory.goals}
              </div>
              <div class="text-xs text-text-secondary mt-1">Goals</div>
            </div>
            <div class="text-center">
              <div class="text-2xl font-510 text-brand">{@preview_plan.inventory.users}</div>
              <div class="text-xs text-text-secondary mt-1">Users</div>
            </div>
            <div class="text-center">
              <div class="text-2xl font-510 text-brand">
                {@preview_plan.inventory.memberships}
              </div>
              <div class="text-xs text-text-secondary mt-1">Memberships</div>
            </div>
            <div class="text-center">
              <div class="text-2xl font-510 text-brand">{@preview_plan.inventory.comments}</div>
              <div class="text-xs text-text-secondary mt-1">Comments</div>
            </div>
            <div class="text-center">
              <div class="text-2xl font-510 text-brand">{@preview_plan.inventory.labels}</div>
              <div class="text-xs text-text-secondary mt-1">Labels</div>
            </div>
          </div>
        </div>

        <div
          data-testid="company-import-target-plan"
          class="mb-6 rounded-lg border border-border bg-subtle p-4"
        >
          <h4 class="text-sm font-510 text-text-primary">Target company plan</h4>
          <p class="mt-2 text-sm text-text-secondary">
            Requested <code class="break-all">{@preview_plan.target.requested_slug}</code>
            <span class="mx-1">→</span>
            <code class="break-all font-510 text-text-primary">{@preview_plan.target.slug}</code>
          </p>
          <p class="mt-2 text-xs text-text-tertiary">
            {@preview_plan.inventory.package_records} package records · {@preview_plan.inventory.planned_writes} planned writes
          </p>
        </div>

        <div class="mb-6 rounded-lg border border-border bg-subtle p-4">
          <div class="mb-3 flex items-center justify-between gap-3">
            <div>
              <h4 class="text-sm font-510 text-text-primary">Secret restore manifest</h4>
              <p class="mt-1 text-xs text-text-secondary">
                Secret values are absent from the export. These entries will be queued for restore after import.
              </p>
            </div>
            <span class="rounded-full border border-amber-500/25 bg-amber-500/10 px-3 py-1 text-xs font-510 text-amber-200">
              {Enum.count(@preview_plan.secret_restore_requirements)} keys
            </span>
          </div>

          <div
            :if={@preview_plan.secret_restore_requirements == []}
            class="text-sm text-text-tertiary"
          >
            No active secrets are listed in this export.
          </div>

          <div
            :if={@preview_plan.secret_restore_requirements != []}
            class="divide-y divide-border"
          >
            <div
              :for={secret <- @preview_plan.secret_restore_requirements}
              class="flex flex-col gap-1 py-3 first:pt-0 last:pb-0 sm:flex-row sm:items-center sm:justify-between"
            >
              <div class="break-all text-sm font-510 text-text-primary">
                {export_field(secret, :key)}
              </div>
              <div class="text-xs text-text-secondary">
                {format_scope(export_field(secret, :scope))}
              </div>
            </div>
          </div>
        </div>

        <div
          :if={@preview_plan.warnings != []}
          data-testid="company-import-warnings"
          class="mb-6 rounded-lg border border-amber-500/20 bg-amber-500/10 p-4 text-amber-200"
        >
          <h4 class="text-sm font-510">Preview warnings</h4>
          <ul class="mt-2 list-disc space-y-1 pl-5 text-sm">
            <li :for={warning <- @preview_plan.warnings}>{warning.message}</li>
          </ul>
        </div>

        <div class="mb-6 rounded-lg border border-border bg-subtle p-4">
          <h4 class="text-sm font-510 text-text-primary">Slug collision policy</h4>
          <p class="mt-2 text-sm text-text-secondary">
            {if @slug_strategy == :fail,
              do: "Stop without importing if the slug already exists.",
              else: "Create a safe -copy slug if the requested slug already exists."}
          </p>
        </div>

        <div class="flex gap-3">
          <button
            phx-click="start_import"
            phx-disable-with="Starting Import…"
            disabled={!@preview_plan.ready? or @validation_errors != []}
            class={[
              "font-510 text-sm px-6 py-3 rounded-button transition-colors inline-flex items-center gap-2",
              (@preview_plan.ready? and @validation_errors == []) &&
                "bg-brand hover:bg-accent text-on-primary",
              (!@preview_plan.ready? or @validation_errors != []) &&
                "cursor-not-allowed bg-subtle text-text-tertiary"
            ]}
          >
            <.icon name="hero-arrow-up-tray-mini" class="h-4 w-4" /> Start Import
          </button>

          <button
            phx-click="reset"
            class="bg-surface hover:bg-surface border border-border text-text-primary font-510 text-sm px-6 py-3 rounded-lg transition-colors"
          >
            Cancel
          </button>
        </div>
      </div>

      <div class="bg-yellow-500/10 border border-yellow-500/20 text-yellow-400 rounded-xl p-4 text-sm">
        <strong>Important:</strong>
        This will create a new company with all the data from the export file. Make sure you have reviewed the contents before proceeding.
      </div>
    </div>
    """
  end

  defp render_step(%{step: :importing} = assigns) do
    ~H"""
    <div
      role="status"
      aria-live="polite"
      aria-busy="true"
      class="rounded-xl border border-border bg-surface p-6 text-center sm:p-12"
    >
      <svg
        class="animate-spin h-16 w-16 mx-auto text-brand mb-6"
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

      <h3 class="font-serif text-xl font-510 text-text-primary mb-2">Importing Company Data</h3>
      <p class="text-text-secondary">{@progress || "Please wait..."}</p>
    </div>
    """
  end

  defp render_step(%{step: :complete, import_result: _import_result} = assigns) do
    ~H"""
    <div class="space-y-6">
      <div class={result_container_class(@import_result)}>
        <div class={result_icon_class(@import_result)}>
          <.icon name={result_icon(@import_result)} class={result_svg_class(@import_result)} />
        </div>

        <h3 class="font-serif text-2xl font-510 text-text-primary mb-2">
          {result_title(@import_result)}
        </h3>

        <p class="text-text-secondary mb-6">
          {result_message(@import_result)}
        </p>

        <div
          :if={import_success?(@import_result)}
          class="bg-subtle border border-border rounded-lg p-4 inline-block"
        >
          <.link
            href={imported_company_path(@import_result)}
            class="text-brand hover:text-accent font-510"
          >
            View imported company
          </.link>
        </div>

        <div
          :if={import_success?(@import_result) and restore_receipt_available?(@import_result)}
          data-testid="import-secret-restore"
          class="mx-auto mt-6 w-full max-w-3xl rounded-lg border border-border bg-subtle p-5 text-left"
        >
          <div class="mb-4 flex flex-col gap-2 sm:flex-row sm:items-end sm:justify-between">
            <div>
              <h4 class="text-sm font-510 text-text-primary">Secret restore queue</h4>
              <p class="mt-1 text-xs leading-5 text-text-secondary">
                Imported companies start without secret values. Add these credentials before assigning runtime work.
              </p>
            </div>
            <span class="inline-flex w-fit items-center gap-2 rounded-full border border-amber-500/25 bg-amber-500/10 px-3 py-1 text-xs font-510 text-amber-200">
              <.icon name="hero-key-mini" class="h-4 w-4" />
              {Enum.count(secrets_to_restore(@import_result))} keys
            </span>
          </div>

          <div :if={secrets_to_restore(@import_result) == []} class="text-sm text-text-tertiary">
            No secret values need to be restored for this import.
          </div>

          <div :if={secrets_to_restore(@import_result) != []} class="divide-y divide-border">
            <div
              :for={secret <- secrets_to_restore(@import_result)}
              class="flex flex-col gap-3 py-4 first:pt-0 last:pb-0 sm:flex-row sm:items-center sm:justify-between"
            >
              <div class="min-w-0">
                <div class="truncate text-sm font-510 text-text-primary">
                  {export_field(secret, :key)}
                </div>
                <div class="mt-1 text-xs text-text-secondary">
                  {format_scope(export_field(secret, :scope))} scope / {restore_status_label(
                    export_field(secret, :restore_status)
                  )}
                </div>
              </div>
              <.link
                href={restore_secret_path(secret, @import_result)}
                class="inline-flex w-fit items-center gap-2 rounded-button border border-border bg-surface px-3 py-2 text-xs font-510 text-text-primary hover:border-brand/40 hover:text-brand"
              >
                <.icon name="hero-key-mini" class="h-4 w-4" /> Add value
              </.link>
            </div>
          </div>
        </div>

        <div
          :if={completed_resume?(@import_result) and not restore_receipt_available?(@import_result)}
          data-testid="import-secret-restore-unavailable"
          class="mx-auto mt-6 w-full max-w-3xl rounded-lg border border-amber-500/25 bg-amber-500/10 p-5 text-left"
        >
          <h4 class="text-sm font-510 text-amber-200">Secret checklist unavailable</h4>
          <p class="mt-1 text-xs leading-5 text-text-secondary">
            This completion receipt does not include a persisted secret restore checklist. Open the imported company and review Secrets before dispatching runtime work.
          </p>
        </div>

        <div
          :if={import_error?(@import_result)}
          class="bg-red-500/10 border border-red-500/20 text-red-400 rounded-lg p-4 max-w-md mx-auto"
        >
          {import_error_message(@import_result)}
        </div>
      </div>

      <div class="flex flex-wrap justify-center gap-3">
        <button
          phx-click="reset"
          class="bg-brand hover:bg-accent text-on-primary font-510 text-sm px-6 py-3 rounded-button transition-colors"
        >
          Import Another
        </button>

        <.app_link
          navigate={~p"/companies"}
          class="bg-surface hover:bg-surface border border-border text-text-primary font-510 text-sm px-6 py-3 rounded-lg transition-colors"
        >
          Back to Companies
        </.app_link>
      </div>
    </div>
    """
  end

  defp import_success?({:ok, _}), do: true
  defp import_success?(_), do: false

  defp completed_resume?({:ok, %{already_completed: true}}), do: true
  defp completed_resume?(_result), do: false

  defp restore_receipt_available?({:ok, %{restore_receipt_available: true}}), do: true
  defp restore_receipt_available?(_result), do: false

  defp preview_ready?(%{ready?: true}), do: true
  defp preview_ready?(_preview_plan), do: false

  defp import_error?({:error, _}), do: true
  defp import_error?(_), do: false

  defp result_container_class({:ok, _}),
    do: "bg-surface border border-border rounded-xl p-6 text-center sm:p-12"

  defp result_container_class({:error, _}),
    do: "bg-surface border border-red-500/20 rounded-xl p-6 text-center sm:p-12"

  defp result_icon_class({:ok, _}),
    do: "w-20 h-20 mx-auto mb-6 rounded-full flex items-center justify-center bg-success/10"

  defp result_icon_class({:error, _}),
    do: "w-20 h-20 mx-auto mb-6 rounded-full flex items-center justify-center bg-brand/10"

  defp result_svg_class({:ok, _}), do: "w-10 h-10 text-success"
  defp result_svg_class({:error, _}), do: "w-10 h-10 text-brand"

  defp result_icon({:ok, _}), do: "hero-check-mini"
  defp result_icon({:error, _}), do: "hero-x-mark-mini"

  defp result_title({:ok, %{already_completed: true}}), do: "Import already complete"
  defp result_title({:ok, _}), do: "Import Successful!"
  defp result_title({:error, _}), do: "Import Failed"

  defp result_message({:ok, %{already_completed: true}}) do
    "This exact export was imported earlier. No data was imported a second time."
  end

  defp result_message({:ok, %{secrets_to_restore: secrets}}) do
    "The company has been imported. #{Enum.count(secrets)} secret values still need to be restored."
  end

  defp result_message({:ok, _}), do: "The company has been imported successfully."
  defp result_message({:error, _}), do: "There was an error importing the company."

  defp import_result_company_id({:ok, %{company: company}}), do: company.id
  defp import_result_company_id({:ok, company}), do: company.id
  defp import_result_company_id(_), do: nil

  defp import_result_return_to(result) do
    case import_result_company_id(result) do
      nil -> "/companies"
      company_id -> "/companies/#{company_id}"
    end
  end

  defp imported_company_path(result) do
    company_id = import_result_company_id(result)
    switch_company_path(company_id, import_result_return_to(result))
  end

  defp import_error_message({:error, msg}), do: msg
  defp import_error_message(_), do: nil

  defp import_command_title(:upload, _preview_plan, _result),
    do: "Import a portable company export"

  defp import_command_title(:uploading, _preview_plan, _result),
    do: "Verifying and uploading your export"

  defp import_command_title(:preview, preview_plan, _result) do
    "Preview #{company_name(preview_plan)} before import"
  end

  defp import_command_title(:importing, preview_plan, _result) do
    "Importing #{company_name(preview_plan)}"
  end

  defp import_command_title(:complete, _preview_plan, {:ok, _result}), do: "Import complete"

  defp import_command_title(:complete, _preview_plan, {:error, _result}),
    do: "Import needs attention"

  defp import_command_title(_step, _preview_plan, _result), do: "Company import"

  defp import_command_summary(:upload, _result, _preview_plan) do
    "Select a Cympho export JSON. Verified resumable parts keep retries fast and secret values remain empty until an owner restores them."
  end

  defp import_command_summary(:uploading, _result, _preview_plan) do
    "The browser is hashing and sending one bounded part at a time. You can cancel now or resume later by selecting the same file."
  end

  defp import_command_summary(:preview, _result, preview_plan) do
    "#{total_import_records(preview_plan)} portable records are ready to import. Review the exact target slug, warnings, and secret restore manifest before continuing."
  end

  defp import_command_summary(:importing, _result, _preview_plan) do
    "Creating the company, remapping scoped records, and preparing the secret restore queue."
  end

  defp import_command_summary(:complete, {:ok, _result}, _preview_plan) do
    "The imported company is available. Restore queued secret values before dispatching runtime work."
  end

  defp import_command_summary(:complete, {:error, _result}, _preview_plan) do
    "The import did not finish. Review the error below and try again."
  end

  defp import_command_summary(_step, _result, _preview_plan),
    do: "Prepare a company import."

  defp import_command_metrics(step, result, preview_plan) do
    [
      %{label: "Stage", value: step_label(step)},
      %{label: "Records", value: total_import_records(preview_plan)},
      %{label: "Secrets", value: import_secret_count(result, preview_plan)},
      %{label: "Slug", value: slug_preview(result, preview_plan)}
    ]
  end

  defp step_label(:upload), do: "Upload"
  defp step_label(:uploading), do: "Transfer"
  defp step_label(:preview), do: "Preview"
  defp step_label(:importing), do: "Running"
  defp step_label(:complete), do: "Complete"
  defp step_label(_), do: "Import"

  defp company_name(%{company: %{name: name}}) when is_binary(name), do: name
  defp company_name(_preview_plan), do: "the company"

  defp total_import_records(%{inventory: %{package_records: count}}), do: count
  defp total_import_records(_preview_plan), do: 0

  defp import_secret_count({:ok, %{secrets_to_restore: secrets}}, _preview_plan)
       when is_list(secrets),
       do: Enum.count(secrets)

  defp import_secret_count(_result, %{secret_restore_requirements: requirements}),
    do: Enum.count(requirements)

  defp import_secret_count(_result, _preview_plan), do: 0

  defp slug_preview({:ok, %{company: %{slug: slug}}}, _preview_plan) when is_binary(slug),
    do: slug

  defp slug_preview(_result, %{target: %{slug: slug}}) when is_binary(slug), do: slug
  defp slug_preview(_result, _preview_plan), do: "Not loaded"

  defp secrets_to_restore({:ok, %{secrets_to_restore: secrets}}) when is_list(secrets),
    do: secrets

  defp secrets_to_restore(_result), do: []

  defp restore_secret_path(secret, result) do
    return_to = import_result_return_to(result)

    params =
      %{
        "key" => export_field(secret, :key),
        "scope" => export_field(secret, :scope, "company"),
        "scope_id" => export_field(secret, :scope_id),
        "description" => restore_description(secret),
        "return_to" => return_to
      }
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)

    destination = "/settings/secrets?#{URI.encode_query(params)}"
    switch_company_path(import_result_company_id(result), destination)
  end

  defp switch_company_path(company_id, return_to) do
    "/switch-company/#{company_id}?#{URI.encode_query(%{"return_to" => return_to})}"
  end

  defp restore_description(secret) do
    export_field(secret, :description) || "Restored from company import"
  end

  defp restore_status_label("missing_scope_target"), do: "scope target missing"
  defp restore_status_label("requires_value"), do: "requires value"
  defp restore_status_label(status) when is_binary(status), do: String.replace(status, "_", " ")
  defp restore_status_label(_status), do: "requires value"

  defp export_field(map, key, default \\ nil)

  defp export_field(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp export_field(_map, _key, default), do: default

  defp format_scope(scope) when is_atom(scope), do: scope |> Atom.to_string() |> format_scope()

  defp format_scope(scope) when is_binary(scope) do
    scope
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp format_scope(_scope), do: "Company"
end
