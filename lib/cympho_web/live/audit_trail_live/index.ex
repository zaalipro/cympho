defmodule CymphoWeb.AuditTrailLive.Index do
  use CymphoWeb, :live_view
  alias Cympho.AuditTrail

  @impl true
  def mount(_params, _session, socket) do
    company_id = get_current_company_id(socket)

    socket =
      socket
      |> assign(:page_title, "Audit Trail")
      |> assign(:company_id, company_id)
      |> assign(:infinite_scroll, %{})
      |> assign(:filter_event_type, "")
      |> assign(:filter_actor_type, "")
      |> assign(:filter_actor_id, "")
      |> assign(:filter_resource_type, "")
      |> assign(:filter_resource_id, "")
      |> assign(:filter_date_from, "")
      |> assign(:filter_date_to, "")
      |> assign(:event_types, [])

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    socket =
      socket
      |> assign(:filter_event_type, params["filter_event_type"] || "")
      |> assign(:filter_actor_type, params["filter_actor_type"] || "")
      |> assign(:filter_actor_id, params["filter_actor_id"] || "")
      |> assign(:filter_resource_type, params["filter_resource_type"] || "")
      |> assign(:filter_resource_id, params["filter_resource_id"] || "")
      |> assign(:filter_date_from, params["filter_date_from"] || "")
      |> assign(:filter_date_to, params["filter_date_to"] || "")
      |> load_event_types()

    {:noreply, init_stream(socket, :events, &fetch_events(socket, &1))}
  end

  @impl true
  def handle_event("filter", attrs, socket) do
    socket =
      socket
      |> assign(:filter_event_type, attrs["filter_event_type"] || "")
      |> assign(:filter_actor_type, attrs["filter_actor_type"] || "")
      |> assign(:filter_actor_id, attrs["filter_actor_id"] || "")
      |> assign(:filter_resource_type, attrs["filter_resource_type"] || "")
      |> assign(:filter_resource_id, attrs["filter_resource_id"] || "")
      |> assign(:filter_date_from, attrs["filter_date_from"] || "")
      |> assign(:filter_date_to, attrs["filter_date_to"] || "")

    {:noreply, push_patch(socket, to: build_url(socket))}
  end

  def handle_event("clear_filters", _, socket) do
    socket =
      socket
      |> assign(:filter_event_type, "")
      |> assign(:filter_actor_type, "")
      |> assign(:filter_actor_id, "")
      |> assign(:filter_resource_type, "")
      |> assign(:filter_resource_id, "")
      |> assign(:filter_date_from, "")
      |> assign(:filter_date_to, "")
      |> push_event("datepicker:reset", %{})

    {:noreply, push_patch(socket, to: ~p"/settings/audit")}
  end

  def handle_event("next-page", _params, socket) do
    {:reply, %{}, load_next(socket, :events, &fetch_events(socket, &1))}
  end

  # Filter forms filter live via phx-change; phx-submit="prevent" only suppresses
  # a full-page submit on Enter, so this is intentionally a no-op.
  def handle_event("prevent", _params, socket), do: {:noreply, socket}

  defp fetch_events(socket, cursor) do
    AuditTrail.list_company_events_page(
      socket.assigns.company_id,
      [after: cursor] ++ filter_opts(socket)
    )
  end

  defp filter_opts(socket) do
    a = socket.assigns

    []
    |> maybe_opt(:event_type, a.filter_event_type)
    |> maybe_opt(:actor_type, a.filter_actor_type)
    |> maybe_opt(:actor_id, a.filter_actor_id)
    |> maybe_opt(:resource_type, a.filter_resource_type)
    |> maybe_opt(:resource_id, a.filter_resource_id)
    |> maybe_date_opt(:start_date, a.filter_date_from, ~T[00:00:00])
    |> maybe_date_opt(:end_date, a.filter_date_to, ~T[23:59:59])
  end

  defp maybe_opt(opts, _key, value) when value in [nil, ""], do: opts
  defp maybe_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp maybe_date_opt(opts, _key, value, _time) when value in [nil, ""], do: opts

  defp maybe_date_opt(opts, key, value, time) do
    case Date.from_iso8601(value) do
      {:ok, date} -> Keyword.put(opts, key, DateTime.new!(date, time))
      _ -> opts
    end
  end

  defp load_event_types(socket) do
    event_types = AuditTrail.list_event_types(socket.assigns.company_id)
    assign(socket, :event_types, event_types)
  end

  defp build_url(socket) do
    a = socket.assigns

    query =
      %{
        filter_event_type: a.filter_event_type,
        filter_actor_type: a.filter_actor_type,
        filter_actor_id: a.filter_actor_id,
        filter_resource_type: a.filter_resource_type,
        filter_resource_id: a.filter_resource_id,
        filter_date_from: a.filter_date_from,
        filter_date_to: a.filter_date_to
      }
      |> Enum.reject(fn {_k, v} -> v in ["", nil] end)
      |> Enum.into(%{})

    ~p"/settings/audit?#{query}"
  end

  defp get_current_company_id(socket) do
    case socket.assigns do
      %{current_company: %{id: id}} -> id
      %{current_user: %{company_id: id}} -> id
      _ -> nil
    end
  end

  # Formatting functions
  def format_event_type(type), do: String.capitalize(String.replace(type, "_", " "))
  def format_actor_type(type), do: String.capitalize(type)

  def format_timestamp(nil), do: ""

  def format_timestamp(datetime) do
    datetime =
      case DateTime.shift_zone(datetime, "America/Los_Angeles") do
        {:ok, shifted} -> shifted
        {:error, _reason} -> datetime
      end

    Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S %Z")
  end

  def format_payload(nil), do: "{}"

  def format_payload(payload) when is_map(payload) do
    payload
    |> Jason.encode!(pretty: true)
  end

  def format_payload(_), do: ""
end
