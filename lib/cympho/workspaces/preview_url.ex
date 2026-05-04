defmodule Cympho.Workspaces.PreviewUrl do
  @moduledoc """
  Handles preview URL generation and proxying for runtime services.
  """

  alias Cympho.Workspaces.RuntimeService

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
    if service.port && service.status == "running" do
      "#{base_url}/preview/#{service.id}"
    else
      nil
    end
  end

  @doc """
  Get the target URL for a runtime service (the actual dev server URL).
  """
  def get_target_url(%RuntimeService{} = service) do
    if service.url do
      service.url
    else
      host = service.cwd |> parse_cwd_for_host() |> default_host()
      "http://#{host}:#{service.port}"
    end
  end

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

  defp parse_cwd_for_host(cwd) do
    case cwd do
      nil -> nil
      _ -> "localhost"
    end
  end

  defp default_host(nil), do: "localhost"
  defp default_host(host) when is_binary(host), do: host

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
