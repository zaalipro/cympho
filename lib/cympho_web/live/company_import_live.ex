defmodule CymphoWeb.CompanyImportLive do
  use CymphoWeb, :live_view

  @inventory_keys ~w(projects agents issues goals users memberships comments labels package_records planned_writes)a
  @secret_keys ~w(key scope scope_id description restore_status)a

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Import a company")
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
    <.page_frame
      id="company-import-transfer"
      phx-hook="CompanyImportTransfer"
      data-base-path="/companies/import/transfers"
      data-transfer-id={@transfer_id}
      page="import"
      kind={:deep}
      parent={{~p"/companies", "Companies"}}
      current="Import"
      data-ui-complex-page
    >
      <:head>
        <section class="head" aria-labelledby="im-h">
          <h1 class="h1 big" id="im-h">Import a company</h1>
          <p class="sub">Restore a portable company export into this instance.</p>
        </section>
      </:head>

      <.flash_line flash={@flash} />

      {render_step(assigns)}
    </.page_frame>
    """
  end

  defp render_step(%{step: step} = assigns) when step in [:upload, :uploading] do
    ~H"""
    <.band_card id="im-file-t" title="Choose a file" data-testid="company-import-command">
      <p class="gl-sub im-line">
        Choose a Cympho JSON export. Large files upload in verified 4 MiB parts, so an interrupted transfer can continue after you select the same file again.
      </p>

      <fieldset class="opts im-opts">
        <legend>If the company slug already exists</legend>
        <div class="opt-w">
          <input
            class="opt-in"
            data-transfer-strategy
            type="radio"
            id="import-slug-suffix"
            name="import_slug_strategy"
            value="suffix"
            checked={@slug_strategy == :suffix}
          />
          <label class="opt" for="import-slug-suffix">
            <span class="on" aria-hidden="true">1</span><span class="ot">Create a safe <span class="mono">-copy</span> slug</span><span
              class="radio"
              aria-hidden="true"
            ></span>
          </label>
        </div>
        <div class="opt-w">
          <input
            class="opt-in"
            data-transfer-strategy
            type="radio"
            id="import-slug-fail"
            name="import_slug_strategy"
            value="fail"
            checked={@slug_strategy == :fail}
          />
          <label class="opt" for="import-slug-fail">
            <span class="on" aria-hidden="true">2</span><span class="ot">Stop without importing</span><span
              class="radio"
              aria-hidden="true"
            ></span>
          </label>
        </div>
        <p class="help">Keep the same choice when resuming an interrupted transfer.</p>
      </fieldset>

      <div id="import-dropzone" data-transfer-dropzone class="im-drop">
        <label for="company-import-file" class="im-drop-l">Choose a company export</label>
        <p id="company-import-file-help" class="help">
          JSON only, up to 50 MB. The browser reads one part at a time and never stores an API token.
        </p>
        <input
          id="company-import-file"
          data-transfer-file
          type="file"
          accept=".json,application/json"
          aria-describedby="company-import-file-help company-import-status"
        />
      </div>

      <%!-- app.js shows this (removes `hidden`) and fills it; no display rule may sit on it. --%>
      <div
        id="company-import-progress"
        data-transfer-progress
        phx-update="ignore"
        class="hidden im-prog"
      >
        <div class="im-prog-h">
          <span data-transfer-filename class="im-fn"></span>
          <span data-transfer-percent class="mono">0%</span>
        </div>
        <div
          class="im-bar"
          role="progressbar"
          aria-label="Company import upload"
          aria-valuemin="0"
          aria-valuemax="100"
          aria-valuenow="0"
          data-transfer-progressbar
        >
          <div data-transfer-progressfill class="im-fill"></div>
        </div>
        <div class="im-prog-f">
          <p
            id="company-import-status"
            data-transfer-status
            role="status"
            aria-live="polite"
            class="help"
          >
            Preparing file…
          </p>
          <button type="button" data-transfer-cancel class="pl">Pause</button>
        </div>
      </div>

      <div
        :if={@validation_errors != []}
        data-testid="company-import-errors"
        role="alert"
        class="im-err"
      >
        <p class="err"><.r3_icon name="i-alert" />Import could not continue</p>
        <ul>
          <li :for={error <- @validation_errors}>{error}</li>
        </ul>
      </div>

      <p class="gl-sub im-line">
        Safe to retry. Re-selecting the same file declares the same content manifest and uploads only missing parts.
      </p>
    </.band_card>
    """
  end

  defp render_step(%{step: :preview, preview_plan: %{} = _preview_plan} = assigns) do
    ~H"""
    <.next_step id="im-ns-" data-testid="company-import-preview">
      <:problem>
        <.problem_card
          title={import_command_title(:preview, @preview_plan, @import_result)}
          title_id="im-ns-t"
        >
          <:eyebrow>Next step<span aria-hidden="true"> · </span>Import</:eyebrow>
          <p class="obj">{import_command_summary(:preview, @import_result, @preview_plan)}</p>
          <div class="strip s3" data-testid="company-import-command">
            <div class="cell">
              <span class="v mono">{total_import_records(@preview_plan)}</span><span class="l">Records</span>
            </div>
            <div class="cell">
              <span class="v mono">{import_secret_count(@import_result, @preview_plan)}</span><span class="l">Secrets to restore</span>
            </div>
            <div class="cell">
              <span class="v mono">{length(@preview_plan.warnings)}</span><span class="l">Warnings</span>
            </div>
          </div>
          <div :if={@validation_errors != []} role="alert" class="im-err">
            <p :for={error <- @validation_errors} class="err">
              <.r3_icon name="i-alert" />{error}
            </p>
          </div>
        </.problem_card>
      </:problem>
      <:resolution>
        <.ink_card heading="After you start it" heading_id="im-ns-i">
          <.consequences rows={import_consequences(@preview_plan)} />
          <.ink_foot verb="import">
            <:secondary>
              <.ghost_pill phx-click="reset">Choose another file</.ghost_pill>
            </:secondary>
            <:primary>
              <.primary_pill
                phx-click="start_import"
                phx-disable-with="Starting import…"
                disabled={!@preview_plan.ready? or @validation_errors != []}
              >
                Start import
              </.primary_pill>
            </:primary>
          </.ink_foot>
        </.ink_card>
      </:resolution>
    </.next_step>

    <.band_card
      id="im-target-t"
      title="Target company plan"
      data-testid="company-import-target-plan"
    >
      <.kv_list class="wide">
        <:item term="Company">{@preview_plan.company.name}</:item>
        <:item term="Version"><span class="mono">{@preview_plan.version}</span></:item>
        <:item term="Slug">
          <span class="mono im-tok">{@preview_plan.target.requested_slug}</span>
          <span aria-hidden="true">→</span><span class="sr">becomes</span>
          <span class="mono im-tok">{@preview_plan.target.slug}</span>
        </:item>
        <:item term="If it exists">
          {if @slug_strategy == :fail,
            do: "Stop without importing if the slug already exists.",
            else: "Create a safe -copy slug if the requested slug already exists."}
        </:item>
        <:item term="Records">
          <span class="mono">{@preview_plan.inventory.package_records}</span>
          package records<span aria-hidden="true"> · </span>
          <span class="mono">
            {@preview_plan.inventory.planned_writes}
          </span>
          planned writes
        </:item>
        <:item term="Contents">{inventory_line(@preview_plan.inventory)}</:item>
      </.kv_list>
    </.band_card>

    <.band_card id="im-secrets-t" title="Secrets to restore">
      <:header_end>
        <span class="meta mono">{Enum.count(@preview_plan.secret_restore_requirements)}</span>
      </:header_end>
      <p class="gl-sub im-line">
        Secret values are not in the export. These entries are queued for restore after import.
      </p>
      <.quiet_empty
        :if={@preview_plan.secret_restore_requirements == []}
        title="No active secrets are listed in this export."
      />
      <ul :if={@preview_plan.secret_restore_requirements != []} class="rows">
        <.list_row
          :for={{secret, n} <- Enum.with_index(@preview_plan.secret_restore_requirements)}
          id={"im-secret-#{n}"}
          title={export_field(secret, :key)}
          icon="i-shield"
        >
          <:meta>{format_scope(export_field(secret, :scope))} scope</:meta>
        </.list_row>
      </ul>
    </.band_card>

    <.band_card
      :if={@preview_plan.warnings != []}
      id="im-warn-t"
      title="Warnings"
      data-testid="company-import-warnings"
    >
      <ul class="rows">
        <.list_row
          :for={{warning, n} <- Enum.with_index(@preview_plan.warnings)}
          id={"im-warning-#{n}"}
          title={warning.message}
          icon="i-alert"
          kind={:problem}
        />
      </ul>
    </.band_card>
    """
  end

  defp render_step(%{step: :importing} = assigns) do
    ~H"""
    <.band_card id="im-run-t" title={import_command_title(:importing, @preview_plan, @import_result)}>
      <div class="gl-sec" role="status" aria-live="polite" aria-busy="true">
        <.now_capsule state={:working}>
          Importing…<:sub>{@progress || "Please wait…"}</:sub>
        </.now_capsule>
        <p class="gl-sub">{import_command_summary(:importing, @import_result, @preview_plan)}</p>
      </div>
    </.band_card>
    """
  end

  defp render_step(%{step: :complete, import_result: _import_result} = assigns) do
    ~H"""
    <.next_step id="im-ns-">
      <:problem>
        <.problem_card title={result_title(@import_result)} title_id="im-ns-t">
          <:eyebrow>{result_eyebrow(@import_result)}</:eyebrow>
          <p class="obj">{result_message(@import_result)}</p>
          <p :if={import_error?(@import_result)} class="err" role="alert">
            <.r3_icon name="i-alert" />{import_error_message(@import_result)}
          </p>
          <:foot>
            <.text_link
              :if={import_success?(@import_result)}
              href={imported_company_path(@import_result)}
            >
              View imported company
            </.text_link>
            <button type="button" class="pl" phx-click="reset">Import another</button>
          </:foot>
        </.problem_card>
      </:problem>
    </.next_step>

    <.band_card
      :if={import_success?(@import_result) and restore_receipt_available?(@import_result)}
      id="im-restore-t"
      title="Secrets to restore"
      data-testid="import-secret-restore"
    >
      <:header_end>
        <span class="meta mono">{Enum.count(secrets_to_restore(@import_result))}</span>
      </:header_end>
      <p class="gl-sub im-line">
        Imported companies start without secret values. Add these before assigning work.
      </p>
      <.quiet_empty
        :if={secrets_to_restore(@import_result) == []}
        title="No secret values need to be restored for this import."
      />
      <ul :if={secrets_to_restore(@import_result) != []} class="rows">
        <.list_row
          :for={{secret, n} <- Enum.with_index(secrets_to_restore(@import_result))}
          id={"im-restore-#{n}"}
          title={export_field(secret, :key)}
          icon="i-shield"
        >
          <:meta>
            {format_scope(export_field(secret, :scope))} scope<span aria-hidden="true"> · </span>{restore_status_label(
              export_field(secret, :restore_status)
            )}
          </:meta>
          <:actions>
            <.pill href={restore_secret_path(secret, @import_result)}>Add value</.pill>
          </:actions>
        </.list_row>
      </ul>
    </.band_card>

    <.band_card
      :if={completed_resume?(@import_result) and not restore_receipt_available?(@import_result)}
      id="im-restore-na-t"
      title="Secret checklist unavailable"
      data-testid="import-secret-restore-unavailable"
    >
      <p class="gl-sub im-line">
        This completion receipt does not include a persisted secret restore checklist. Open the imported company and review Secrets before dispatching runtime work.
      </p>
    </.band_card>
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

  defp result_title({:ok, %{already_completed: true}}), do: "Import already complete"
  defp result_title({:ok, %{company: %{name: name}}}) when is_binary(name), do: "Imported #{name}"
  defp result_title({:ok, _}), do: "Import complete"
  defp result_title({:error, _}), do: "Import failed"

  defp result_eyebrow({:ok, %{secrets_to_restore: [_ | _]}}), do: "Next step · Restore secrets"
  defp result_eyebrow({:ok, _}), do: "All clear · Import"
  defp result_eyebrow(_result), do: "Next step · Import"

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

  defp import_command_title(:preview, preview_plan, _result) do
    "Preview #{company_name(preview_plan)} before import"
  end

  defp import_command_title(:importing, preview_plan, _result) do
    "Importing #{company_name(preview_plan)}"
  end

  defp import_command_summary(:preview, _result, preview_plan) do
    "#{total_import_records(preview_plan)} portable records are ready to import. Review the exact target slug, warnings, and secret restore manifest before continuing."
  end

  defp import_command_summary(:importing, _result, _preview_plan) do
    "Creating the company, remapping scoped records, and preparing the secret restore queue."
  end

  defp import_consequences(preview_plan) do
    secrets = Enum.count(preview_plan.secret_restore_requirements)

    created =
      {:done,
       "Creates #{company_name(preview_plan)} as a new company at #{preview_plan.target.slug || "a new slug"}."}

    if secrets > 0,
      do: [
        created,
        {:waiting, "#{secrets} secret values to restore afterwards; they are not in the file."}
      ],
      else: [created]
  end

  defp inventory_line(inventory) do
    [
      {inventory.projects, "projects"},
      {inventory.agents, "agents"},
      {inventory.issues, "tasks"},
      {inventory.goals, "goals"},
      {inventory.users, "users"},
      {inventory.memberships, "memberships"},
      {inventory.comments, "comments"},
      {inventory.labels, "labels"}
    ]
    |> Enum.map_join(" · ", fn {count, word} -> "#{count || 0} #{word}" end)
  end

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
