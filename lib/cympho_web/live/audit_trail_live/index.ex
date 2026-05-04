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
      |> assign(:events, [])
      |> assign(:pagination, %{total: 0, limit: 50, offset: 0, page: 1, total_pages: 1})
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
    filter_event_type = params["filter_event_type"] || ""
    filter_actor_type = params["filter_actor_type"] || ""
    filter_actor_id = params["filter_actor_id"] || ""
    filter_resource_type = params["filter_resource_type"] || ""
    filter_resource_id = params["filter_resource_id"] || ""
    filter_date_from = params["filter_date_from"] || ""
    filter_date_to = params["filter_date_to"] || ""
    page = String.to_integer(params["page"] || "1")

    socket =
      socket
      |> assign(:filter_event_type, filter_event_type)
      |> assign(:filter_actor_type, filter_actor_type)
      |> assign(:filter_actor_id, filter_actor_id)
      |> assign(:filter_resource_type, filter_resource_type)
      |> assign(:filter_resource_id, filter_resource_id)
      |> assign(:filter_date_from, filter_date_from)
      |> assign(:filter_date_to, filter_date_to)
      |> assign(:page, page)
      |> load_events()
      |> load_event_types()

    {:noreply, socket}
  end

  @impl true
  def handle_event("filter", attrs, socket) do
    filter_event_type = attrs["filter_event_type"] || ""
    filter_actor_type = attrs["filter_actor_type"] || ""
    filter_actor_id = attrs["filter_actor_id"] || ""
    filter_resource_type = attrs["filter_resource_type"] || ""
    filter_resource_id = attrs["filter_resource_id"] || ""
    filter_date_from = attrs["filter_date_from"] || ""
    filter_date_to = attrs["filter_date_to"] || ""

    socket =
      socket
      |> assign(:filter_event_type, filter_event_type)
      |> assign(:filter_actor_type, filter_actor_type)
      |> assign(:filter_actor_id, filter_actor_id)
      |> assign(:filter_resource_type, filter_resource_type)
      |> assign(:filter_resource_id, filter_resource_id)
      |> assign(:filter_date_from, filter_date_from)
      |> assign(:filter_date_to, filter_date_to)
      |> assign(:page, 1)
      |> load_events()
      |> load_event_types()

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
      |> assign(:page, 1)
      |> load_events()
      |> load_event_types()

    {:noreply, push_patch(socket, to: ~p"/audit-trail")}
  end

  def handle_event("load_more", _, socket) do
    socket =
      socket
      |> update(:page, &(&1 + 1))
      |> load_events()

    {:noreply, push_patch(socket, to: build_url(socket))}
  end

  def handle_event("load_prev", _, socket) do
    socket =
      socket
      |> update(:page, &max(1, &1 - 1))
      |> load_events()

    {:noreply, push_patch(socket, to: build_url(socket))}
  end

  defp load_events(socket) do
    company_id = socket.assigns.company_id
    filter_event_type = socket.assigns.filter_event_type
    filter_actor_type = socket.assigns.filter_actor_type
    filter_actor_id = socket.assigns.filter_actor_id
    filter_resource_type = socket.assigns.filter_resource_type
    filter_resource_id = socket.assigns.filter_resource_id
    filter_date_from = socket.assigns.filter_date_from
    filter_date_to = socket.assigns.filter_date_to
    page = socket.assigns.page
    limit = 50
    offset = (page - 1) * limit

    opts = [limit: limit, offset: offset]

    opts =
      if filter_event_type != "" do
        Keyword.put(opts, :event_type, filter_event_type)
      else
        opts
      end

    opts =
      if filter_actor_type != "" do
        Keyword.put(opts, :actor_type, filter_actor_type)
      else
        opts
      end

    opts =
      if filter_actor_id != "" do
        Keyword.put(opts, :actor_id, filter_actor_id)
      else
        opts
      end

    opts =
      if filter_resource_type != "" do
        Keyword.put(opts, :resource_type, filter_resource_type)
      else
        opts
      end

    opts =
      if filter_resource_id != "" do
        Keyword.put(opts, :resource_id, filter_resource_id)
      else
        opts
      end

    opts =
      if filter_date_from != "" do
        case Date.from_iso8601(filter_date_from) do
          {:ok, date} ->
            Keyword.put(opts, :start_date, DateTime.new!(date, ~T[00:00:00]))

          _ ->
            opts
        end
      else
        opts
      end

    opts =
      if filter_date_to != "" do
        case Date.from_iso8601(filter_date_to) do
          {:ok, date} ->
            Keyword.put(opts, :end_date, DateTime.new!(date, ~T[23:59:59]))

          _ ->
            opts
        end
      else
        opts
      end

    {events, total} = AuditTrail.list_company_events(company_id, opts)

    socket
    |> assign(:events, events)
    |> assign(:pagination, %{
      total: total,
      limit: limit,
      offset: offset,
      page: page,
      total_pages: ceil(max(1, total) / limit)
    })
  end

  defp load_event_types(socket) do
    company_id = socket.assigns.company_id
    event_types = AuditTrail.list_event_types(company_id)
    assign(socket, :event_types, event_types)
  end

  defp build_url(socket) do
    filter_event_type = socket.assigns.filter_event_type
    filter_actor_type = socket.assigns.filter_actor_type
    filter_actor_id = socket.assigns.filter_actor_id
    filter_resource_type = socket.assigns.filter_resource_type
    filter_resource_id = socket.assigns.filter_resource_id
    filter_date_from = socket.assigns.filter_date_from
    filter_date_to = socket.assigns.filter_date_to
    page = socket.assigns.page

    query =
      %{
        filter_event_type: filter_event_type,
        filter_actor_type: filter_actor_type,
        filter_actor_id: filter_actor_id,
        filter_resource_type: filter_resource_type,
        filter_resource_id: filter_resource_id,
        filter_date_from: filter_date_from,
        filter_date_to: filter_date_to,
        page: page
      }
      |> Enum.reject(fn {_k, v} -> v in ["", nil] end)
      |> Enum.into(%{})

    ~p"/audit-trail?#{query}"
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
