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
    <.page_frame
      page="export"
      kind={:deep}
      parent={{~p"/companies/#{@company}", @company.name}}
      current="Export"
      data-ui-complex-page
    >
      <:head>
        <section class="head" aria-labelledby="ex-h">
          <h1 class="h1 big" id="ex-h">Export</h1>
        </section>
      </:head>

      <.flash_line flash={@flash} />

      <% exported? = @download_ready && @export_data %>
      <.next_step id="ex-ns-" data-testid="company-export-command">
        <:problem>
          <.problem_card title={"Export #{@company.name}"} title_id="ex-ns-t">
            <:eyebrow>Next step<span aria-hidden="true"> · </span>Export</:eyebrow>
            <p :if={!exported?} class="obj">
              Move the company graph, work queues, agents, goals, labels, memberships, and task history into another Cympho instance. Secret values stay out of the file; only a restore checklist is included.
            </p>
            <p :if={exported?} class="obj">
              Exported {exported_day(@export_data.exported_at)}
              <span class="mono">{exported_clock(@export_data.exported_at)}</span><span aria-hidden="true"> · </span>version
              <span class="mono">{@export_data.version}</span>
            </p>
          </.problem_card>
        </:problem>
        <:resolution>
          <.ink_card
            heading={if exported?, do: "After you download it", else: "After you generate it"}
            heading_id="ex-ns-i"
          >
            <.consequences
              :if={!exported?}
              rows={[
                {:done, "Cympho builds one JSON file here; nothing leaves until you download it."}
              ]}
            />
            <.consequences
              :if={exported?}
              rows={[
                {:done, "The file is saved on this device. Secret values are not in it."}
              ]}
            />
            <.ink_note :if={@loading}>Generating export…</.ink_note>
            <.ink_note>
              The file still contains company work content, comments, and operating metadata. Store it with the same care as a production backup.
            </.ink_note>
            <.ink_foot :if={!@loading} verb={!exported? && "generate"}>
              <:secondary :if={exported?}>
                <.ghost_pill phx-click="generate_export">Regenerate export</.ghost_pill>
              </:secondary>
              <:primary>
                <%!-- A native anchor: <.link> refuses data: hrefs (v7 §2.3). --%>
                <a
                  :if={exported?}
                  class="pw"
                  download={"#{@company.slug}-export-#{Date.utc_today()}.json"}
                  href={download_href(@export_data)}
                >
                  Download JSON<span class="nub"><.r3_icon name="i-arrow-right" /></span>
                </a>
                <.primary_pill :if={!exported?} phx-click="generate_export">
                  Generate export
                </.primary_pill>
              </:primary>
            </.ink_foot>
          </.ink_card>
        </:resolution>
      </.next_step>

      <.band_card :if={exported?} id="ex-inventory-t" title="What is in the file">
        <.kv_list class="wide">
          <:item :for={metric <- export_metrics(@export_data)} term={metric.label}>
            <span class="mono">{metric.value}</span>
          </:item>
        </.kv_list>
      </.band_card>

      <.band_card
        id="ex-secrets-t"
        title="Secrets to restore"
        data-testid="secret-restore-manifest"
      >
        <:header_end>
          <span class="meta mono">
            {Enum.count(active_secret_manifest(@export_data, @secret_manifest))}
          </span>
        </:header_end>
        <p class="gl-sub ex-line">
          The file names each secret and its scope only. Values must be entered again in the destination company.
        </p>
        <.quiet_empty
          :if={active_secret_manifest(@export_data, @secret_manifest) == []}
          title="No active secrets are recorded for this company."
        />
        <ul :if={active_secret_manifest(@export_data, @secret_manifest) != []} class="rows">
          <.list_row
            :for={
              {secret, n} <- Enum.with_index(active_secret_manifest(@export_data, @secret_manifest))
            }
            id={"ex-secret-#{n}"}
            title={secret.key}
            icon="i-shield"
          >
            <:meta>
              {format_scope(secret.scope)} scope<span :if={secret.scope_id}><span aria-hidden="true"> · </span>scoped target kept</span><span aria-hidden="true"> · </span>{secret.description ||
                "No description"}
            </:meta>
          </.list_row>
        </ul>
      </.band_card>
    </.page_frame>
    """
  end

  # exported_at is an ISO 8601 string: "Sun 25 Oct" and the mono clock (v7 §1.7).
  defp exported_day(at), do: format_exported(at, "%a %-d %b", at)
  defp exported_clock(at), do: format_exported(at, "%H:%M", nil)

  defp format_exported(at, format, fallback) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, datetime, _offset} -> Calendar.strftime(datetime, format)
      _ -> fallback
    end
  end

  defp format_exported(_at, _format, fallback), do: fallback

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
      %{label: "Tasks", value: export_count(export_data, :issues)},
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
