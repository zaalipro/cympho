defmodule Cympho.OpenTelemetry.Instrumentation do
  @moduledoc false

  require OpenTelemetry.Tracer

  alias OpenTelemetry.{Ctx, Span, Tracer}

  @handler_id "cympho-open-telemetry"
  @events [
    [:phoenix, :endpoint, :start],
    [:phoenix, :endpoint, :stop],
    [:phoenix, :endpoint, :exception],
    [:phoenix, :router_dispatch, :start],
    [:cympho, :issue, :created],
    [:cympho, :dispatcher, :dispatch],
    [:cympho, :dispatcher, :stalled_wakeup],
    [:cympho, :routing, :classified],
    [:cympho, :run, :lifecycle],
    [:cympho, :tool, :call],
    [:cympho, :tool, :complete]
  ]

  @run_actions %{
    "run_created" => "created",
    "run_started" => "started",
    "run_completed" => "completed",
    "run_failed" => "failed",
    "run_cancelled" => "cancelled",
    "run_recovered_stale" => "recovered"
  }

  @spec setup() :: :ok | {:error, term()}
  def setup do
    case :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, %{}) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
      error -> error
    end
  end

  @spec teardown() :: :ok
  def teardown do
    :telemetry.detach(@handler_id)
    :ok
  end

  @doc false
  def handle_event([:phoenix, :endpoint, :start], _measurements, %{conn: conn}, _config) do
    safely(fn -> start_http_span(conn) end)
  end

  def handle_event([:phoenix, :endpoint, :stop], _measurements, %{conn: conn}, _config) do
    safely(fn -> finish_http_span(conn.status, nil) end)
  end

  def handle_event(
        [:phoenix, :endpoint, :exception],
        _measurements,
        metadata,
        _config
      ) do
    safely(fn ->
      status = metadata |> Map.get(:conn, %{}) |> Map.get(:status)
      finish_http_span(status, exception_type(Map.get(metadata, :reason)))
    end)
  end

  def handle_event(
        [:phoenix, :router_dispatch, :start],
        _measurements,
        %{conn: conn, route: route},
        _config
      ) do
    safely(fn ->
      with {:ok, route} <- safe_route(route) do
        method = safe_method(conn.method)
        Tracer.update_name("#{method} #{route}")
        Tracer.set_attribute("http.route", route)
      end
    end)
  end

  def handle_event(event, measurements, metadata, _config) do
    safely(fn -> emit_domain_span(span_spec(event, measurements, metadata)) end)
  end

  @doc false
  def span_spec([:cympho, :issue, :created], _measurements, metadata) do
    spec(
      "cympho.issue.created",
      [
        {"cympho.company.id", safe_label(value(metadata, :company_id))},
        {"cympho.project.id", safe_label(value(metadata, :project_id))},
        {"cympho.issue.id", safe_label(value(metadata, :issue_id))},
        {"cympho.issue.status", safe_label(value(metadata, :status))},
        {"cympho.issue.priority", safe_label(value(metadata, :priority))}
      ],
      false
    )
  end

  def span_spec([:cympho, :run, :lifecycle], measurements, metadata) do
    action = metadata |> value(:action) |> normalize_run_action()

    spec(
      "cympho.run.#{action}",
      [
        {"cympho.run.lifecycle", action},
        {"cympho.run.id", safe_label(value(metadata, :run_id))},
        {"cympho.company.id", safe_label(value(metadata, :company_id))},
        {"cympho.agent.id", safe_label(value(metadata, :agent_id))},
        {"cympho.issue.id", safe_label(value(metadata, :issue_id))},
        {"cympho.run.status", safe_label(value(metadata, :status))},
        {"cympho.adapter.type", safe_label(value(metadata, :adapter))},
        {"cympho.run.duration_ms", safe_number(value(measurements, :duration_ms))}
      ],
      action == "failed"
    )
  end

  def span_spec([:cympho, :dispatcher, :dispatch], measurements, metadata) do
    status = safe_label(value(metadata, :status)) || "unknown"

    spec(
      "cympho.dispatch.#{status}",
      [
        {"cympho.dispatch.status", status},
        {"cympho.company.id", safe_label(value(metadata, :company_id))},
        {"cympho.issue.id", safe_label(value(metadata, :issue_id))},
        {"cympho.agent.id", safe_label(value(metadata, :agent_id))},
        {"cympho.role", safe_label(value(metadata, :role))},
        {"cympho.dispatch.attempt", safe_number(value(measurements, :attempt))},
        {"cympho.dispatch.backoff_ms", safe_number(value(measurements, :backoff_ms))}
      ],
      false
    )
  end

  def span_spec([:cympho, :dispatcher, :stalled_wakeup], measurements, metadata) do
    spec(
      "cympho.dispatch.stalled_wakeup",
      [
        {"cympho.company.id", safe_label(value(metadata, :company_id))},
        {"cympho.issue.id", safe_label(value(metadata, :issue_id))},
        {"cympho.role", safe_label(value(metadata, :role))},
        {"cympho.dispatch.age_ms", safe_number(value(measurements, :age_ms))}
      ],
      false
    )
  end

  def span_spec([:cympho, :routing, :classified], measurements, metadata) do
    spec(
      "cympho.routing.classified",
      [
        {"cympho.issue.id", safe_label(value(metadata, :issue_id))},
        {"cympho.role", safe_label(value(metadata, :classified_role))},
        {"cympho.routing.source", safe_label(value(measurements, :source))},
        {"cympho.routing.duration_ms", safe_number(value(measurements, :duration_ms))}
      ],
      false
    )
  end

  def span_spec([:cympho, :tool, event], measurements, metadata)
      when event in [:call, :complete] do
    status = safe_label(value(metadata, :status))

    spec(
      "cympho.tool.#{event}",
      [
        {"cympho.tool.name", safe_label(value(metadata, :tool_name))},
        {"cympho.tool_call.id", safe_label(value(metadata, :trace_id))},
        {"cympho.company.id", safe_label(value(metadata, :company_id))},
        {"cympho.agent.id", safe_label(value(metadata, :agent_id))},
        {"cympho.issue.id", safe_label(value(metadata, :issue_id))},
        {"cympho.tool.status", status},
        {"cympho.tool.duration_ms", safe_number(value(measurements, :duration_ms))}
      ],
      status in ["error", "timeout"]
    )
  end

  def span_spec(_, _, _), do: :ignore

  @doc false
  def http_span_spec(conn) do
    method = safe_method(conn.method)

    %{
      name: "HTTP #{method}",
      attributes: %{"http.request.method" => method},
      propagation_headers:
        Enum.filter(conn.req_headers, fn {name, _value} ->
          String.downcase(name) in ["traceparent", "tracestate"]
        end)
    }
  end

  @doc false
  def extract_parent(headers) when is_list(headers) do
    headers
    |> Enum.filter(fn {name, _value} ->
      String.downcase(name) in ["traceparent", "tracestate"]
    end)
    |> then(&:otel_propagator_text_map.extract(:otel_propagator_trace_context, &1))
  end

  defp start_http_span(conn) do
    spec = http_span_spec(conn)

    _token = extract_parent(spec.propagation_headers)

    Tracer.start_span(spec.name, %{
      kind: :server,
      attributes: spec.attributes
    })
    |> Tracer.set_current_span()
  end

  defp finish_http_span(status, exception_type) do
    if is_integer(status) do
      Tracer.set_attribute("http.response.status_code", status)
    end

    if is_binary(exception_type) do
      Tracer.set_attribute("error.type", exception_type)
    end

    if is_binary(exception_type) or (is_integer(status) and status >= 500) do
      Tracer.set_status(OpenTelemetry.status(:error, ""))
    end

    Tracer.end_span()
    Ctx.clear()
  end

  defp emit_domain_span(:ignore), do: :ok

  defp emit_domain_span({:ok, name, attributes, error?}) do
    span =
      Tracer.start_span(name, %{
        kind: :internal,
        attributes: attributes
      })

    if error?, do: Span.set_status(span, OpenTelemetry.status(:error, ""))
    Span.end_span(span)
    :ok
  end

  defp spec(name, pairs, error?) do
    attributes =
      pairs
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    {:ok, name, attributes, error?}
  end

  defp normalize_run_action(action) when is_atom(action),
    do: normalize_run_action(Atom.to_string(action))

  defp normalize_run_action(action) when is_binary(action),
    do: Map.get(@run_actions, action, "updated")

  defp normalize_run_action(_), do: "updated"

  defp safe_method(method)
       when method in ~w(GET POST PUT PATCH DELETE HEAD OPTIONS CONNECT TRACE),
       do: method

  defp safe_method(_), do: "OTHER"

  defp safe_route(route) when is_binary(route) do
    if byte_size(route) <= 256 and Regex.match?(~r{\A/[A-Za-z0-9_./:*~-]*\z}, route),
      do: {:ok, route},
      else: :error
  end

  defp safe_route(_), do: :error

  defp safe_label(value) when is_atom(value), do: value |> Atom.to_string() |> safe_label()

  defp safe_label(value) when is_binary(value) do
    if byte_size(value) <= 128 and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_.:-]*\z/, value),
      do: value,
      else: nil
  end

  defp safe_label(_), do: nil

  defp safe_number(value) when is_integer(value) and value >= 0, do: value
  defp safe_number(value) when is_float(value) and value >= 0, do: value
  defp safe_number(_), do: nil

  defp exception_type(%module{}) when is_atom(module), do: safe_label(module)
  defp exception_type(_), do: "unknown"

  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp value(_, _), do: nil

  defp safely(fun) do
    fun.()
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
