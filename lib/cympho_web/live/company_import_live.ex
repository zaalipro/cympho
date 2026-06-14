defmodule CymphoWeb.CompanyImportLive do
  use CymphoWeb, :live_view

  alias Cympho.Companies

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Import Company")
     |> assign(:step, :upload)
     |> assign(:upload_data, nil)
     |> assign(:import_data, nil)
     |> assign(:validation_errors, [])
     |> assign(:slug_strategy, :suffix)
     |> assign(:importing, false)
     |> assign(:import_result, nil)
     |> assign(:progress, nil)
     |> allow_upload(:import_file,
       accept: ~w(.json),
       max_entries: 1,
       max_file_size: 50_000_000
     )}
  end

  @impl true
  def handle_event("validate_upload", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :import_file, ref)}
  end

  @impl true
  def handle_event("proceed_to_preview", _params, socket) do
    {consuming, _} = uploaded_entries(socket, :import_file)

    if consuming == [] do
      {:noreply, put_flash(socket, :error, "Please select a file to import")}
    else
      socket
      |> consume_uploaded_entries(:import_file, fn %{path: path}, _entry ->
        case File.read(path) do
          {:ok, content} ->
            data = Jason.decode!(content)
            {:ok, data}

          {:error, _reason} ->
            {:error, "Failed to read file"}
        end
      end)
      |> case do
        [%{} = import_data] ->
          validation_errors = validate_import_data(import_data)

          {:noreply,
           socket
           |> assign(:import_data, import_data)
           |> assign(:validation_errors, validation_errors)
           |> assign(:step, if(validation_errors == [], do: :preview, else: :upload))}

        _error ->
          {:noreply, put_flash(socket, :error, "Failed to process uploaded file")}
      end
    end
  end

  @impl true
  def handle_event("set_slug_strategy", %{"strategy" => strategy}, socket) do
    {:noreply, assign(socket, :slug_strategy, String.to_existing_atom(strategy))}
  end

  @impl true
  def handle_event("start_import", _params, socket) do
    send(self(), :do_import)

    {:noreply,
     socket
     |> assign(:importing, true)
     |> assign(:step, :importing)
     |> assign(:progress, "Starting import...")}
  end

  @impl true
  def handle_event("reset", _params, socket) do
    {:noreply,
     socket
     |> assign(:step, :upload)
     |> assign(:import_data, nil)
     |> assign(:validation_errors, [])
     |> assign(:import_result, nil)
     |> assign(:progress, nil)
     |> allow_upload(:import_file,
       accept: ~w(.json),
       max_entries: 1,
       max_file_size: 50_000_000
     )}
  end

  @impl true
  def handle_info(:do_import, socket) do
    import_data = socket.assigns.import_data
    slug_strategy = socket.assigns.slug_strategy

    result =
      try do
        case Companies.import_company(import_data, slug_strategy: slug_strategy) do
          {:ok, %{company: company} = import_result} ->
            # Emit a pubsub notification for real-time updates
            CymphoWeb.Endpoint.broadcast("companies:lobby", "company_imported", %{
              company_id: company.id
            })

            {:ok, import_result}

          {:error, _reason} = error ->
            error
        end
      rescue
        e -> {:error, Exception.message(e)}
      end

    {:noreply,
     socket
     |> assign(:importing, false)
     |> assign(:import_result, result)
     |> assign(:step, :complete)
     |> assign(:progress, nil)}
  end

  defp validate_import_data(data) do
    errors = []

    errors =
      if Map.has_key?(data, "company") do
        errors
      else
        ["Missing company data" | errors]
      end

    company_data = Map.get(data, "company", %{})

    errors =
      if Map.has_key?(company_data, "name") && Map.get(company_data, "name") != "" do
        errors
      else
        ["Company name is required" | errors]
      end

    errors =
      if Map.has_key?(company_data, "slug") && Map.get(company_data, "slug") != "" do
        errors
      else
        ["Company slug is required" | errors]
      end

    errors =
      if Map.has_key?(data, "version") do
        errors
      else
        ["Missing export version" | errors]
      end

    Enum.reverse(errors)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-6 lg:p-8 max-w-6xl mx-auto">
      <.header title="Import Company">
        <:actions>
          <.app_link
            navigate={~p"/companies"}
            class="text-text-secondary hover:text-text-primary text-sm"
          >
            Back to Companies
          </.app_link>
        </:actions>
      </.header>

      <section
        data-testid="company-import-command"
        class="mb-6 overflow-hidden rounded-xl border border-border bg-surface"
      >
        <div class="grid gap-0 lg:grid-cols-[minmax(0,1.35fr)_minmax(300px,0.65fr)]">
          <div class="p-6 lg:p-8">
            <div class="mb-4 inline-flex items-center gap-2 rounded-full border border-brand/20 bg-brand/10 px-3 py-1 text-xs font-510 text-brand">
              <.icon name="hero-arrow-up-tray-mini" class="h-4 w-4" /> Company portability
            </div>
            <h2 class="font-serif text-2xl font-510 text-text-primary">
              {import_command_title(@step, @import_data, @import_result)}
            </h2>
            <p class="mt-3 max-w-2xl text-sm leading-6 text-text-secondary">
              {import_command_summary(@step, @import_data, @import_result)}
            </p>
          </div>

          <div class="border-t border-border bg-subtle/60 p-6 lg:border-l lg:border-t-0 lg:p-8">
            <div class="grid grid-cols-2 gap-3">
              <div
                :for={metric <- import_command_metrics(@step, @import_data, @import_result)}
                class="rounded-lg border border-border bg-surface p-4"
              >
                <div class="text-lg font-510 text-text-primary">{metric.value}</div>
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
    """
  end

  defp render_step(%{step: :upload} = assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="bg-surface border border-border rounded-xl p-6">
        <h3 class="font-serif text-lg font-510 text-text-primary mb-4">Upload Export File</h3>
        <p class="text-text-secondary text-sm mb-6">
          Select a JSON export file to import. The file should contain a complete company export including projects, agents, issues, and other data.
        </p>

        <.form
          for={%{}}
          id="company-import-upload"
          phx-change="validate_upload"
          phx-submit="proceed_to_preview"
          class="space-y-6"
        >
          <div
            id="import-dropzone"
            phx-drop-target={@uploads.import_file.ref}
            class="rounded-xl border-2 border-dashed border-border bg-subtle/50 p-10 text-center transition-colors hover:border-brand/50"
          >
            <span class="mx-auto mb-4 flex h-12 w-12 items-center justify-center rounded-xl bg-brand/10 text-brand">
              <.icon name="hero-document-arrow-up-mini" class="h-6 w-6" />
            </span>

            <div class="text-text-primary mb-2">Drop a company export JSON here</div>
            <div class="text-text-tertiary text-sm mb-4">or choose one from disk</div>

            <label class="inline-flex cursor-pointer items-center gap-2 rounded-button bg-brand px-5 py-3 text-sm font-510 text-on-primary transition-colors hover:bg-accent">
              <.icon name="hero-folder-open-mini" class="h-4 w-4" /> Browse files
              <.live_file_input upload={@uploads.import_file} class="hidden" />
            </label>
          </div>

          <div :if={@uploads.import_file.entries != []}>
            <% entry = Enum.at(@uploads.import_file.entries, 0) %>
            <div class="flex items-center justify-between rounded-lg border border-border bg-subtle p-4">
              <div class="flex items-center gap-3">
                <.icon name="hero-document-text-mini" class="h-5 w-5 text-brand" />
                <div>
                  <div class="text-text-primary text-sm font-510">
                    {entry.client_name}
                  </div>
                  <div class="text-text-tertiary text-xs">
                    {format_file_size(entry.client_size)}
                  </div>
                </div>
              </div>
              <button
                type="button"
                phx-click="cancel_upload"
                phx-value-ref={entry.ref}
                class="text-red-400 hover:text-red-300 text-sm"
              >
                Remove
              </button>
            </div>

            <button
              type="submit"
              class="mt-4 w-full rounded-button bg-brand px-6 py-3 text-sm font-510 text-on-primary transition-colors hover:bg-accent"
            >
              Continue to Preview
            </button>
          </div>
        </.form>

        <div
          :if={@validation_errors != []}
          class="mt-6 bg-red-500/10 border border-red-500/20 text-red-400 rounded-xl p-4"
        >
          <h4 class="font-510 mb-2">Validation Errors:</h4>
          <ul class="list-disc list-inside text-sm space-y-1">
            <li :for={error <- @validation_errors}>{error}</li>
          </ul>
        </div>
      </div>

      <div class="bg-blue-500/10 border border-blue-500/20 text-blue-400 rounded-xl p-4 text-sm">
        <strong>Tip:</strong>
        The import creates a new company. If the slug already exists, keep the suffix strategy unless you intentionally want the import to fail.
      </div>
    </div>
    """
  end

  defp render_step(%{step: :preview, import_data: _import_data} = assigns) do
    ~H"""
    <div class="space-y-6">
      <div data-testid="company-import-preview" class="bg-surface border border-border rounded-xl p-6">
        <h3 class="font-serif text-lg font-510 text-text-primary mb-4">Preview Import</h3>

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
            <div>
              <h4 class="text-xl font-510 text-text-primary">{@import_data["company"]["name"]}</h4>
              <div class="text-text-secondary text-sm">
                <code class="bg-black/20 px-2 py-1 rounded">{@import_data["company"]["slug"]}</code>
              </div>
            </div>
          </div>

          <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
            <div class="text-center">
              <div class="text-2xl font-510 text-brand">
                {Enum.count(@import_data["projects"] || [])}
              </div>
              <div class="text-xs text-text-secondary mt-1">Projects</div>
            </div>
            <div class="text-center">
              <div class="text-2xl font-510 text-brand">
                {Enum.count(@import_data["agents"] || [])}
              </div>
              <div class="text-xs text-text-secondary mt-1">Agents</div>
            </div>
            <div class="text-center">
              <div class="text-2xl font-510 text-brand">
                {Enum.count(@import_data["issues"] || [])}
              </div>
              <div class="text-xs text-text-secondary mt-1">Issues</div>
            </div>
            <div class="text-center">
              <div class="text-2xl font-510 text-brand">
                {Enum.count(@import_data["goals"] || [])}
              </div>
              <div class="text-xs text-text-secondary mt-1">Goals</div>
            </div>
          </div>
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
              {Enum.count(secret_manifest(@import_data))} keys
            </span>
          </div>

          <div :if={secret_manifest(@import_data) == []} class="text-sm text-text-tertiary">
            No active secrets are listed in this export.
          </div>

          <div :if={secret_manifest(@import_data) != []} class="divide-y divide-border">
            <div
              :for={secret <- secret_manifest(@import_data)}
              class="flex flex-col gap-1 py-3 first:pt-0 last:pb-0 sm:flex-row sm:items-center sm:justify-between"
            >
              <div class="text-sm font-510 text-text-primary">{export_field(secret, :key)}</div>
              <div class="text-xs text-text-secondary">
                {format_scope(export_field(secret, :scope))}
              </div>
            </div>
          </div>
        </div>

        <div class="mb-6">
          <h4 class="text-sm font-510 text-text-primary mb-3">Slug Collision Strategy</h4>
          <div class="flex gap-4">
            <label class="flex items-center gap-2 cursor-pointer">
              <input
                type="radio"
                name="slug_strategy"
                value="suffix"
                checked={@slug_strategy == :suffix}
                phx-click="set_slug_strategy"
                phx-value-strategy="suffix"
                class="w-4 h-4 text-brand"
              />
              <span class="text-sm text-text-secondary">Auto-generate suffix</span>
            </label>
            <label class="flex items-center gap-2 cursor-pointer">
              <input
                type="radio"
                name="slug_strategy"
                value="fail"
                checked={@slug_strategy == :fail}
                phx-click="set_slug_strategy"
                phx-value-strategy="fail"
                class="w-4 h-4 text-brand"
              />
              <span class="text-sm text-text-secondary">Fail on collision</span>
            </label>
          </div>
        </div>

        <div class="flex gap-3">
          <button
            phx-click="start_import"
            class="bg-brand hover:bg-accent text-on-primary font-510 text-sm px-6 py-3 rounded-button transition-colors inline-flex items-center gap-2"
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
    <div class="bg-surface border border-border rounded-xl p-12 text-center">
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
          <.app_link
            navigate={~p"/companies/#{import_result_company_id(@import_result)}"}
            class="text-brand hover:text-accent font-510"
          >
            View imported company
          </.app_link>
        </div>

        <div
          :if={import_success?(@import_result)}
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
              <.app_link
                navigate={restore_secret_path(secret, import_result_return_to(@import_result))}
                class="inline-flex w-fit items-center gap-2 rounded-button border border-border bg-surface px-3 py-2 text-xs font-510 text-text-primary hover:border-brand/40 hover:text-brand"
              >
                <.icon name="hero-key-mini" class="h-4 w-4" /> Add value
              </.app_link>
            </div>
          </div>
        </div>

        <div
          :if={import_error?(@import_result)}
          class="bg-red-500/10 border border-red-500/20 text-red-400 rounded-lg p-4 max-w-md mx-auto"
        >
          {import_error_message(@import_result)}
        </div>
      </div>

      <div class="flex gap-3 justify-center">
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

  defp import_error?({:error, _}), do: true
  defp import_error?(_), do: false

  defp result_container_class({:ok, _}),
    do: "bg-surface border border-border rounded-xl p-12 text-center"

  defp result_container_class({:error, _}),
    do: "bg-surface border border-red-500/20 rounded-xl p-12 text-center"

  defp result_icon_class({:ok, _}),
    do: "w-20 h-20 mx-auto mb-6 rounded-full flex items-center justify-center bg-success/10"

  defp result_icon_class({:error, _}),
    do: "w-20 h-20 mx-auto mb-6 rounded-full flex items-center justify-center bg-brand/10"

  defp result_svg_class({:ok, _}), do: "w-10 h-10 text-success"
  defp result_svg_class({:error, _}), do: "w-10 h-10 text-brand"

  defp result_icon({:ok, _}), do: "hero-check-mini"
  defp result_icon({:error, _}), do: "hero-x-mark-mini"

  defp result_title({:ok, _}), do: "Import Successful!"
  defp result_title({:error, _}), do: "Import Failed"

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

  defp import_error_message({:error, msg}), do: msg
  defp import_error_message(_), do: nil

  defp import_command_title(:upload, _import_data, _result),
    do: "Import a portable company export"

  defp import_command_title(:preview, import_data, _result) do
    "Preview #{company_name(import_data)} before import"
  end

  defp import_command_title(:importing, import_data, _result) do
    "Importing #{company_name(import_data)}"
  end

  defp import_command_title(:complete, _import_data, {:ok, _result}), do: "Import complete"

  defp import_command_title(:complete, _import_data, {:error, _result}),
    do: "Import needs attention"

  defp import_command_title(_step, _import_data, _result), do: "Company import"

  defp import_command_summary(:upload, _import_data, _result) do
    "Upload a Cympho export JSON. The import creates a new company and keeps secret values empty until an owner restores them."
  end

  defp import_command_summary(:preview, import_data, _result) do
    "#{total_import_records(import_data)} portable records are ready to import. Review the slug strategy and secret restore manifest before continuing."
  end

  defp import_command_summary(:importing, _import_data, _result) do
    "Creating the company, remapping scoped records, and preparing the secret restore queue."
  end

  defp import_command_summary(:complete, _import_data, {:ok, _result}) do
    "The imported company is available. Restore queued secret values before dispatching runtime work."
  end

  defp import_command_summary(:complete, _import_data, {:error, _result}) do
    "The import did not finish. Review the error below, adjust the export or slug strategy, and try again."
  end

  defp import_command_summary(_step, _import_data, _result), do: "Prepare a company import."

  defp import_command_metrics(step, import_data, result) do
    [
      %{label: "Stage", value: step_label(step)},
      %{label: "Records", value: total_import_records(import_data)},
      %{label: "Secrets", value: import_secret_count(import_data, result)},
      %{label: "Slug", value: slug_preview(import_data, result)}
    ]
  end

  defp step_label(:upload), do: "Upload"
  defp step_label(:preview), do: "Preview"
  defp step_label(:importing), do: "Running"
  defp step_label(:complete), do: "Complete"
  defp step_label(_), do: "Import"

  defp company_name(nil), do: "the company"

  defp company_name(import_data) do
    import_data
    |> export_field(:company, %{})
    |> export_field(:name, "the company")
  end

  defp total_import_records(nil), do: 0

  defp total_import_records(import_data) do
    [:projects, :agents, :issues, :goals, :labels, :memberships]
    |> Enum.map(fn key -> import_data |> export_field(key, []) |> Enum.count() end)
    |> Enum.sum()
  end

  defp import_secret_count(_import_data, {:ok, %{secrets_to_restore: secrets}})
       when is_list(secrets),
       do: Enum.count(secrets)

  defp import_secret_count(import_data, _result), do: Enum.count(secret_manifest(import_data))

  defp slug_preview(_import_data, {:ok, %{company: %{slug: slug}}}) when is_binary(slug), do: slug

  defp slug_preview(import_data, _result) do
    import_data
    |> export_field(:company, %{})
    |> export_field(:slug, "Not loaded")
  end

  defp secret_manifest(nil), do: []
  defp secret_manifest(import_data), do: export_field(import_data, :secret_manifest, [])

  defp secrets_to_restore({:ok, %{secrets_to_restore: secrets}}) when is_list(secrets),
    do: secrets

  defp secrets_to_restore(_result), do: []

  defp restore_secret_path(secret, return_to) do
    params =
      %{
        "key" => export_field(secret, :key),
        "scope" => export_field(secret, :scope, "company"),
        "scope_id" => export_field(secret, :scope_id),
        "description" => restore_description(secret),
        "return_to" => return_to
      }
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)

    "/settings/secrets?#{URI.encode_query(params)}"
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

  defp format_file_size(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_000_000 -> "#{Float.round(bytes / 1_000_000, 1)} MB"
      bytes >= 1_000 -> "#{Float.round(bytes / 1_000, 1)} KB"
      true -> "#{bytes} B"
    end
  end
end
