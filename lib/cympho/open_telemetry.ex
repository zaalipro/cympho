defmodule Cympho.OpenTelemetry do
  @moduledoc """
  Optional, fail-open OpenTelemetry startup.

  The SDK and exporter are runtime-disabled dependencies. They are started only
  when an OTLP endpoint is configured, so tracing cannot affect the default
  Cympho boot path.
  """

  require Logger

  alias Cympho.OpenTelemetry.Instrumentation

  @default_service_name "cympho"
  @supported_protocols %{
    "grpc" => :grpc,
    "http/protobuf" => :http_protobuf,
    "http_protobuf" => :http_protobuf
  }

  @type setup_result :: {:ok, :disabled | :enabled | {:degraded, atom()}}

  @doc """
  Starts the optional SDK and installs Cympho's allowlisted instrumentation.

  Failures are contained and returned as a degraded no-op. `:start_fun` and
  `:instrument_fun` are dependency-injection seams used by focused boot tests.
  """
  @spec setup(keyword()) :: setup_result()
  def setup(opts \\ []) do
    start_fun = Keyword.get(opts, :start_fun, &start_sdk/1)
    instrument_fun = Keyword.get(opts, :instrument_fun, &Instrumentation.setup/0)

    case settings(opts) do
      {:ok, :disabled} ->
        {:ok, :disabled}

      {:ok, config} ->
        with :ok <- safe_call(fn -> start_fun.(config) end, :sdk_start_failed),
             :ok <- safe_call(instrument_fun, :instrumentation_failed) do
          {:ok, :enabled}
        else
          {:error, reason} -> degraded(reason)
        end

      {:error, reason} ->
        degraded(reason)
    end
  rescue
    _ -> degraded(:configuration_failed)
  catch
    _, _ -> degraded(:configuration_failed)
  end

  @doc false
  @spec settings(keyword()) :: {:ok, :disabled | map()} | {:error, atom()}
  def settings(opts \\ []) do
    app_config = Application.get_env(:cympho, :open_telemetry, [])
    endpoint = option(opts, app_config, :endpoint)

    if blank?(endpoint) do
      {:ok, :disabled}
    else
      traces_endpoint = option(opts, app_config, :traces_endpoint)
      service_name = option(opts, app_config, :service_name) || @default_service_name
      deployment_environment = option(opts, app_config, :deployment_environment) || "unknown"
      protocol = option(opts, app_config, :protocol) || "http_protobuf"

      with :ok <- validate_endpoint(endpoint),
           :ok <- validate_optional_endpoint(traces_endpoint),
           {:ok, protocol} <- normalize_protocol(protocol),
           :ok <- validate_label(service_name),
           :ok <- validate_label(deployment_environment) do
        {:ok,
         %{
           endpoint: endpoint,
           traces_endpoint: blank_to_nil(traces_endpoint),
           protocol: protocol,
           service_name: service_name,
           service_version: service_version(),
           deployment_environment: deployment_environment
         }}
      end
    end
  end

  defp start_sdk(config) do
    configure_sdk(config)

    with :ok <- load_exporter(),
         {:ok, _} <- Application.ensure_all_started(:opentelemetry_exporter),
         {:ok, _} <- Application.ensure_all_started(:opentelemetry) do
      :ok
    else
      _ -> {:error, :sdk_start_failed}
    end
  end

  defp configure_sdk(config) do
    resource = %{
      "service.name" => config.service_name,
      "service.version" => config.service_version,
      "deployment.environment.name" => config.deployment_environment
    }

    Application.put_env(:opentelemetry, :span_processor, :batch)
    Application.put_env(:opentelemetry, :traces_exporter, :otlp)
    Application.put_env(:opentelemetry, :metrics_exporter, :none)
    Application.put_env(:opentelemetry, :text_map_propagators, [:trace_context])
    Application.put_env(:opentelemetry, :resource_detectors, [:otel_resource_app_env])
    Application.put_env(:opentelemetry, :resource, resource)
    Application.put_env(:opentelemetry, :attribute_value_length_limit, 256)

    Application.put_env(:opentelemetry_exporter, :otlp_endpoint, config.endpoint)
    Application.put_env(:opentelemetry_exporter, :otlp_protocol, config.protocol)

    if config.traces_endpoint do
      Application.put_env(
        :opentelemetry_exporter,
        :otlp_traces_endpoint,
        config.traces_endpoint
      )

      Application.put_env(:opentelemetry_exporter, :otlp_traces_protocol, config.protocol)
    end

    :ok
  end

  defp load_exporter do
    case Application.load(:opentelemetry_exporter) do
      :ok -> :ok
      {:error, {:already_loaded, :opentelemetry_exporter}} -> :ok
      _ -> {:error, :sdk_start_failed}
    end
  end

  defp safe_call(fun, failure_reason) do
    case fun.() do
      :ok -> :ok
      {:ok, _} -> :ok
      _ -> {:error, failure_reason}
    end
  rescue
    _ -> {:error, failure_reason}
  catch
    _, _ -> {:error, failure_reason}
  end

  defp degraded(reason) do
    Logger.warning(
      "OpenTelemetry export is disabled; Cympho will continue without external traces",
      component: "open_telemetry",
      failure: reason
    )

    {:ok, {:degraded, reason}}
  end

  defp validate_optional_endpoint(value) do
    if blank?(value), do: :ok, else: validate_endpoint(value)
  end

  defp validate_endpoint(endpoint) when is_binary(endpoint) do
    uri = URI.parse(endpoint)

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and
         is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment) do
      :ok
    else
      {:error, :invalid_endpoint}
    end
  end

  defp validate_endpoint(_), do: {:error, :invalid_endpoint}

  defp normalize_protocol(protocol) when is_atom(protocol),
    do: normalize_protocol(Atom.to_string(protocol))

  defp normalize_protocol(protocol) when is_binary(protocol) do
    case Map.fetch(@supported_protocols, String.downcase(protocol)) do
      {:ok, normalized} -> {:ok, normalized}
      :error -> {:error, :invalid_protocol}
    end
  end

  defp normalize_protocol(_), do: {:error, :invalid_protocol}

  defp validate_label(value) when is_binary(value) do
    if Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\z/, value) do
      :ok
    else
      {:error, :invalid_resource_label}
    end
  end

  defp validate_label(_), do: {:error, :invalid_resource_label}

  defp option(opts, app_config, key) do
    if Keyword.has_key?(opts, key),
      do: Keyword.get(opts, key),
      else: Keyword.get(app_config, key)
  end

  defp service_version do
    case Application.spec(:cympho, :vsn) do
      version when is_list(version) -> List.to_string(version)
      version when is_binary(version) -> version
      _ -> "unknown"
    end
  end

  defp blank?(value), do: value in [nil, ""]
  defp blank_to_nil(value), do: if(blank?(value), do: nil, else: value)
end
