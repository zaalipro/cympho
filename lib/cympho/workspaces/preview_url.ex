defmodule Cympho.Workspaces.PreviewUrl do
  @moduledoc """
  Handles preview URL generation and proxying for runtime services.
  """

  alias Cympho.Workspaces.RuntimeService

  @token_salt "runtime preview capability"

  # Common dev server ports for auto-discovery
  @common_dev_ports [
    {3000, "webpack", ["node", "webpack", "vite"]},
    {3001, "webpack-alt", ["node", "webpack", "vite"]},
    {5173, "vite", ["vite"]},
    {5174, "vite-alt", ["vite"]},
    {8080, "webpack-dev-server", ["webpack", "serve"]},
    {4200, "angular", ["ng", "angular"]},
    {4000, "next", ["next"]},
    {5000, "flask", ["flask"]},
    {8000, "django", ["django", "python"]},
    {9200, "elasticsearch", ["elasticsearch"]},
    {5601, "kibana", ["kibana"]},
    {5432, "postgres", ["postgres", "postmaster"]},
    {6379, "redis", ["redis"]},
    {27017, "mongodb", ["mongod"]},
    {8888, "jupyter", ["jupyter", "notebook"]},
    {1234, "ruby", ["ruby", "rails", "rackup"]},
    {5000, "python", ["python", "gunicorn", "uvicorn"]}
  ]

  @doc """
  Generate a preview URL for a runtime service.
  Returns a proxied URL that routes through the application.
  """
  def generate_preview_url(%RuntimeService{} = service, base_url) do
    with true <- previewable?(service),
         preview_host when is_binary(preview_host) <- preview_host(),
         {:ok, base_uri} <- URI.new(base_url),
         true <- base_uri.host != nil and normalize_host(base_uri.host) != preview_host do
      token = sign_capability(service)

      base_uri
      |> Map.put(:host, preview_host)
      |> Map.put(:path, "/api/preview/#{service.id}/#{token}/proxy")
      |> Map.put(:query, nil)
      |> Map.put(:fragment, nil)
      |> URI.to_string()
    else
      _ -> nil
    end
  end

  @doc false
  def sign_capability(%RuntimeService{} = service, opts \\ []) do
    Phoenix.Token.sign(
      CymphoWeb.Endpoint,
      @token_salt,
      %{service_id: service.id, preview_ref: service.preview_ref},
      opts
    )
  end

  @doc "Verifies a short-lived preview capability and returns its preview identity."
  def verify_capability(service_id, token) when is_binary(service_id) and is_binary(token) do
    max_age = Application.get_env(:cympho, :preview_token_max_age, 300)

    case Phoenix.Token.verify(CymphoWeb.Endpoint, @token_salt, token, max_age: max_age) do
      {:ok, %{service_id: ^service_id, preview_ref: preview_ref}}
      when is_binary(preview_ref) ->
        {:ok, preview_ref}

      {:ok, %{"service_id" => ^service_id, "preview_ref" => preview_ref}}
      when is_binary(preview_ref) ->
        {:ok, preview_ref}

      _ ->
        {:error, :invalid_capability}
    end
  end

  def verify_capability(_service_id, _token), do: {:error, :invalid_capability}

  @doc "Returns the configured cookie-free preview hostname."
  def preview_host, do: Application.get_env(:cympho, :preview_host)

  @doc """
  Get the Finch target for a runtime service.

  Always loopback. `service.url` is a display field and is ignored.
  """
  def get_target_url(%RuntimeService{} = service) do
    if previewable?(service), do: "http://127.0.0.1:#{service.port}"
  end

  def previewable?(%RuntimeService{
        status: "running",
        port: port,
        preview_ref: preview_ref,
        execution_workspace_id: execution_workspace_id
      })
      when is_integer(port) and port in 1..65535 and is_binary(preview_ref) and
             is_binary(execution_workspace_id),
      do: true

  def previewable?(_service), do: false

  defp normalize_host(host), do: host |> String.downcase() |> String.trim_trailing(".")

  @doc """
  Auto-discover common dev server ports by examining running processes.
  Returns a list of {port, service_name, confidence} tuples.
  """
  def auto_discover_ports(cwd) when is_binary(cwd) do
    case System.cmd("lsof", ["-i", "-P", "-n", "-p", "#{System.pid()}"], cd: cwd) do
      {output, 0} ->
        discover_from_lsof_output(output)

      _ ->
        # Fallback: check common ports by attempting connection
        discover_from_common_ports()
    end
  end

  @doc """
  Scan a directory for common dev server configuration files to infer likely ports.
  """
  def infer_ports_from_project(cwd) when is_binary(cwd) do
    inferred = []

    inferred =
      if File.exists?("#{cwd}/package.json"), do: [{3000, "node", 0.8} | inferred], else: inferred

    inferred =
      if File.exists?("#{cwd}/vite.config.ts") or File.exists?("#{cwd}/vite.config.js"),
        do: [{5173, "vite", 0.9} | inferred],
        else: inferred

    inferred =
      if File.exists?("#{cwd}/webpack.config.js") or File.exists?("#{cwd}/webpack.config.ts"),
        do: [{3000, "webpack", 0.8} | inferred],
        else: inferred

    inferred =
      if File.exists?("#{cwd}/next.config.js") or File.exists?("#{cwd}/next.config.ts"),
        do: [{3000, "next", 0.9} | inferred],
        else: inferred

    inferred =
      if File.exists?("#{cwd}/requirements.txt") or File.exists?("#{cwd}/Pipfile"),
        do: [{5000, "python", 0.7} | inferred],
        else: inferred

    inferred =
      if File.exists?("#{cwd}/Gemfile"), do: [{3000, "ruby", 0.7} | inferred], else: inferred

    inferred =
      if File.exists?("#{cwd}/go.mod"), do: [{8080, "go", 0.6} | inferred], else: inferred

    inferred
  end

  @doc """
  Returns the list of common dev server ports with metadata.
  """
  def common_ports, do: @common_dev_ports

  defp discover_from_lsof_output(output) do
    output
    |> String.split("\n")
    |> Enum.reduce([], fn line, acc ->
      case parse_lsof_line(line) do
        {port, protocol} when protocol in ["TCP", "UDP"] and is_integer(port) ->
          [{port, "lsof", 1.0} | acc]

        _ ->
          acc
      end
    end)
  end

  defp parse_lsof_line(line) do
    # Example line: COMMAND  PID  USER  FD  TYPE  DEVICE  SIZE/OFF  NODE  NAME
    # Or: ruby    1234  user  5u  IPv4  0x...  0t0  TCP  *:3000 (LISTEN)
    with true <- String.contains?(line, "LISTEN"),
         [_, _, _, _, _, _, _, _, name_part | _] <- String.split(line, ~r{\s+}, parts: 10),
         true <- String.contains?(name_part, ":") do
      [_, port_str] = String.split(name_part, ":")
      {String.to_integer(port_str), "TCP"}
    else
      _ -> :error
    end
  end

  defp discover_from_common_ports do
    @common_dev_ports
    |> Enum.take(5)
    |> Enum.map(fn {port, name, _confidence} -> {port, name, 0.3} end)
  end
end
