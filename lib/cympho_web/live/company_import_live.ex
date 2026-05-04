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
      consume_uploaded_entries(socket, :import_file, fn %{path: path}, _entry ->
        case File.read(path) do
          {:ok, content} ->
            data = Jason.decode!(content)
            {:ok, data}

          {:error, _reason} ->
            {:error, "Failed to read file"}
        end
      end)
      |> case do
        {[%{} = import_data], socket} ->
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
          {:ok, %{company: company}} = _result ->
            # Emit a pubsub notification for real-time updates
            CymphoWeb.Endpoint.broadcast("companies:lobby", "company_imported", %{
              company_id: company.id
            })

            {:ok, company}

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

        <div
          id="import-dropzone"
          phx-drop-target={@uploads.import_file.ref}
          class="border-2 border-dashed border-border rounded-lg p-12 text-center hover:border-brand/50 transition-colors"
        >
          <svg
            class="mx-auto h-12 w-12 text-text-tertiary mb-4"
            fill="none"
            stroke="currentColor"
            viewBox="0 0 24 24"
          >
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M7 16a4 4 0 01-.88-7.903A5 5 0 1115.9 6L16 6a5 5 0 011 9.9M15 13l-3-3m0 0l-3 3m3-3v12"
            />
          </svg>

          <div class="text-text-primary mb-2">Drag and drop your export file here</div>
          <div class="text-text-tertiary text-sm mb-4">or</div>

          <label class="bg-brand hover:bg-accent text-white font-510 text-sm px-6 py-3 rounded-lg transition-colors inline-flex items-center gap-2 cursor-pointer">
            <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M4 16v1a3 3 0 003 3h10a3 3 0 003-3v-1m-4-8l-4-4m0 0L8 8m4-4v12"
              />
            </svg>
            Browse Files
            <.input
              type="file"
              class="hidden"
              phx-hook="fileSelect"
              phx-upload={@uploads.import_file.ref}
              phx_change="validate_upload"
            />
          </label>
        </div>

        <div :if={@uploads.import_file.entries != []} class="mt-6">
          <div class="flex items-center justify-between bg-subtle border border-border rounded-lg p-4">
            <div class="flex items-center gap-3">
              <svg class="w-5 h-5 text-brand" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z"
                />
              </svg>
              <div>
                <div class="text-text-primary text-sm font-510">
                  {Enum.at(@uploads.import_file.entries, 0).client_name}
                </div>
                <div class="text-text-tertiary text-xs">
                  {format_file_size(Enum.at(@uploads.import_file.entries, 0).client_size)}
                </div>
              </div>
            </div>
            <button
              phx-click="cancel_upload"
              phx-value-ref={Enum.at(@uploads.import_file.entries, 0).ref}
              class="text-red-400 hover:text-red-300 text-sm"
            >
              Remove
            </button>
          </div>

          <button
            phx-click="proceed_to_preview"
            class="mt-4 w-full bg-brand hover:bg-accent text-white font-510 text-sm px-6 py-3 rounded-lg transition-colors"
          >
            Continue to Preview
          </button>
        </div>

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
        The import will create a new company. If a company with the same slug exists, you can choose to either fail the import or automatically generate a unique slug suffix.
      </div>
    </div>
    """
  end

  defp render_step(%{step: :preview, import_data: _import_data} = assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="bg-surface border border-border rounded-xl p-6">
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
            Start Import
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
          <svg
            class={result_svg_class(@import_result)}
            fill="none"
            stroke="currentColor"
            viewBox="0 0 24 24"
          >
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d={result_icon_path(@import_result)}
            />
          </svg>
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
            View Imported Company →
          </.app_link>
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
          class="bg-brand hover:bg-accent text-white font-510 text-sm px-6 py-3 rounded-lg transition-colors"
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
    do: "w-20 h-20 mx-auto mb-6 rounded-full flex items-center justify-center bg-red-500/10"

  defp result_svg_class({:ok, _}), do: "w-10 h-10 text-success"
  defp result_svg_class({:error, _}), do: "w-10 h-10 text-red-400"

  defp result_icon_path({:ok, _}), do: "M5 13l4 4L19 7"
  defp result_icon_path({:error, _}), do: "M6 18L18 6M6 6l12 12"

  defp result_title({:ok, _}), do: "Import Successful!"
  defp result_title({:error, _}), do: "Import Failed"

  defp result_message({:ok, _}), do: "The company has been imported successfully."
  defp result_message({:error, _}), do: "There was an error importing the company."

  defp import_result_company_id({:ok, company}), do: company.id
  defp import_result_company_id(_), do: nil

  defp import_error_message({:error, msg}), do: msg
  defp import_error_message(_), do: nil

  defp format_file_size(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_000_000 -> "#{Float.round(bytes / 1_000_000, 1)} MB"
      bytes >= 1_000 -> "#{Float.round(bytes / 1_000, 1)} KB"
      true -> "#{bytes} B"
    end
  end
end
