defmodule Cympho.RuntimeAdmission.MemoryProbe do
  @moduledoc """
  Reads normalized host and cgroup memory availability for runtime admission.

  Only byte counters and a bounded source atom leave this module. File paths,
  file contents, and operating-system errors are never returned.
  """

  @meminfo_path "/proc/meminfo"
  @self_cgroup_path "/proc/self/cgroup"
  @cgroup_v2_root "/sys/fs/cgroup"
  @cgroup_v1_memory_root "/sys/fs/cgroup/memory"
  @v1_unlimited_min 0x7FFF_FFFF_F000_0000

  @type source :: :host | :cgroup | :host_and_cgroup
  @type sample :: %{
          available_bytes: non_neg_integer(),
          total_bytes: pos_integer(),
          source: source()
        }

  @spec sample() :: {:ok, sample()} | {:error, :unavailable}
  def sample do
    case sample(&File.read/1) do
      {:ok, _sample} = result -> result
      {:error, :unavailable} -> maybe_os_mon_system_sample()
    end
  end

  @doc false
  @spec sample((String.t() -> {:ok, binary()} | {:error, term()})) ::
          {:ok, sample()} | {:error, :unavailable}
  def sample(read_fun) when is_function(read_fun, 1) do
    host = read_host(read_fun)

    with {:ok, cgroup} <- read_cgroup(read_fun) do
      effective_sample(host, cgroup)
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  @doc false
  @spec system_sample((-> keyword() | map())) :: {:ok, sample()} | {:error, :unavailable}
  def system_sample(system_fun) when is_function(system_fun, 0) do
    data = system_fun.()
    available = system_value(data, :available_memory)
    total = system_value(data, :system_total_memory)
    normalized_sample(available, total, :host)
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp read_host(read_fun) do
    with {:ok, contents} <- safe_read(read_fun, @meminfo_path),
         {:ok, total_kb} <- meminfo_value(contents, "MemTotal"),
         {:ok, available_kb} <- meminfo_value(contents, "MemAvailable") do
      %{total_bytes: total_kb * 1024, available_bytes: available_kb * 1024}
    else
      _ -> nil
    end
  end

  defp read_cgroup(read_fun) do
    case optional_read(read_fun, @self_cgroup_path) do
      {:ok, contents} ->
        memberships = cgroup_memberships(contents)
        read_cgroup_membership(read_fun, memberships)

      :missing ->
        # No cgroup membership interface means there is no detected memory
        # containment to account for; the host sample remains authoritative.
        {:ok, nil}

      {:error, :unavailable} ->
        {:error, :unavailable}
    end
  end

  defp cgroup_memberships(contents) do
    lines = String.split(contents, "\n", trim: true)

    %{
      v2:
        Enum.find_value(lines, fn line ->
          case String.split(line, ":", parts: 3) do
            ["0", "", path] when path != "" -> path
            _ -> nil
          end
        end),
      v1:
        Enum.find_value(lines, fn line ->
          case String.split(line, ":", parts: 3) do
            [_hierarchy, controllers, path] when path != "" ->
              if "memory" in String.split(controllers, ","), do: path

            _ ->
              nil
          end
        end)
    }
  end

  defp read_cgroup_membership(_read_fun, %{v2: nil, v1: nil}), do: {:ok, nil}

  defp read_cgroup_membership(read_fun, %{v2: relative, v1: v1_relative})
       when is_binary(relative) do
    case read_cgroup_hierarchy(
           read_fun,
           @cgroup_v2_root,
           relative,
           "memory.max",
           "memory.current",
           &v2_limit/1
         ) do
      {:ok, _sample} = result ->
        result

      {:error, :not_configured} when is_binary(v1_relative) ->
        read_v1_cgroup(read_fun, v1_relative)

      {:error, :not_configured} ->
        read_v2_cgroup_ancestors(read_fun, relative)

      {:error, :unavailable} = error ->
        error
    end
  end

  defp read_cgroup_membership(read_fun, %{v2: nil, v1: relative}) when is_binary(relative),
    do: read_v1_cgroup(read_fun, relative)

  defp read_v1_cgroup(read_fun, relative) do
    case read_cgroup_hierarchy(
           read_fun,
           @cgroup_v1_memory_root,
           relative,
           "memory.limit_in_bytes",
           "memory.usage_in_bytes",
           &v1_limit/1
         ) do
      {:error, :not_configured} -> {:error, :unavailable}
      result -> result
    end
  end

  defp read_v2_cgroup_ancestors(read_fun, relative) do
    with {:ok, leaf} <- confined_directory(@cgroup_v2_root, relative) do
      leaf
      |> hierarchy(@cgroup_v2_root)
      |> tl()
      |> read_first_configured_hierarchy(read_fun, "memory.max", "memory.current", &v2_limit/1)
    end
  end

  defp read_first_configured_hierarchy([], _read_fun, _limit_file, _usage_file, _parse_limit),
    do: {:ok, nil}

  defp read_first_configured_hierarchy(
         [directory | ancestors],
         read_fun,
         limit_file,
         usage_file,
         parse_limit
       ) do
    case optional_read(read_fun, Path.join(directory, limit_file)) do
      {:ok, _contents} ->
        with {:ok, constraints} <-
               read_constraints(
                 read_fun,
                 [directory | ancestors],
                 limit_file,
                 usage_file,
                 parse_limit
               ) do
          case constraints do
            [] -> {:ok, nil}
            constraints -> {:ok, tightest_constraint(constraints)}
          end
        end

      :missing ->
        read_first_configured_hierarchy(
          ancestors,
          read_fun,
          limit_file,
          usage_file,
          parse_limit
        )

      {:error, :unavailable} = error ->
        error
    end
  end

  defp read_cgroup_hierarchy(read_fun, root, relative, limit_file, usage_file, parse_limit) do
    with {:ok, leaf} <- confined_directory(root, relative) do
      case optional_read(read_fun, Path.join(leaf, limit_file)) do
        {:ok, _contents} ->
          with {:ok, constraints} <-
                 read_constraints(
                   read_fun,
                   hierarchy(leaf, root),
                   limit_file,
                   usage_file,
                   parse_limit
                 ) do
            case constraints do
              [] -> {:ok, nil}
              constraints -> {:ok, tightest_constraint(constraints)}
            end
          end

        :missing ->
          {:error, :not_configured}

        {:error, :unavailable} ->
          {:error, :unavailable}
      end
    end
  end

  defp confined_directory(root, relative) do
    candidate = Path.expand("." <> relative, root)

    if candidate == root or String.starts_with?(candidate, root <> "/"),
      do: {:ok, candidate},
      else: {:error, :unavailable}
  end

  defp hierarchy(root, root), do: [root]
  defp hierarchy(leaf, root), do: [leaf | hierarchy(Path.dirname(leaf), root)]

  defp read_constraints(read_fun, directories, limit_file, usage_file, parse_limit) do
    Enum.reduce_while(directories, {:ok, []}, fn directory, {:ok, constraints} ->
      with {:ok, contents} <- safe_read(read_fun, Path.join(directory, limit_file)),
           {:ok, limit} <- parse_limit.(contents) do
        case limit do
          :unlimited ->
            {:cont, {:ok, constraints}}

          limit ->
            with {:ok, usage_contents} <- safe_read(read_fun, Path.join(directory, usage_file)),
                 {:ok, usage} <- non_negative_integer(usage_contents) do
              constraint = %{total_bytes: limit, available_bytes: max(limit - usage, 0)}
              {:cont, {:ok, [constraint | constraints]}}
            else
              _ -> {:halt, {:error, :unavailable}}
            end
        end
      else
        _ -> {:halt, {:error, :unavailable}}
      end
    end)
  end

  defp tightest_constraint(constraints) do
    %{
      total_bytes: constraints |> Enum.map(& &1.total_bytes) |> Enum.min(),
      available_bytes: constraints |> Enum.map(& &1.available_bytes) |> Enum.min()
    }
  end

  defp v2_limit(contents) do
    if String.trim(contents) == "max", do: {:ok, :unlimited}, else: positive_integer(contents)
  end

  defp v1_limit(contents) do
    case positive_integer(contents) do
      {:ok, limit} when limit >= @v1_unlimited_min -> {:ok, :unlimited}
      result -> result
    end
  end

  defp effective_sample(nil, nil), do: {:error, :unavailable}

  defp effective_sample(%{} = host, nil) do
    normalized_sample(host.available_bytes, host.total_bytes, :host)
  end

  defp effective_sample(nil, %{} = cgroup) do
    normalized_sample(cgroup.available_bytes, cgroup.total_bytes, :cgroup)
  end

  defp effective_sample(%{} = host, %{} = cgroup) do
    normalized_sample(
      min(host.available_bytes, cgroup.available_bytes),
      min(host.total_bytes, cgroup.total_bytes),
      :host_and_cgroup
    )
  end

  defp normalized_sample(available, total, source)
       when is_integer(available) and is_integer(total) and total > 0 do
    {:ok,
     %{
       available_bytes: available |> max(0) |> min(total),
       total_bytes: total,
       source: source
     }}
  end

  defp normalized_sample(_available, _total, _source), do: {:error, :unavailable}

  defp meminfo_value(contents, key) do
    contents
    |> String.split("\n", trim: true)
    |> Enum.find_value({:error, :unavailable}, fn line ->
      case String.split(line, ~r/\s+/, trim: true) do
        [^key <> ":", value, "kB"] -> positive_integer(value)
        _ -> nil
      end
    end)
  end

  defp positive_integer(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _ -> {:error, :unavailable}
    end
  end

  defp non_negative_integer(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} when integer >= 0 -> {:ok, integer}
      _ -> {:error, :unavailable}
    end
  end

  defp safe_read(read_fun, path) do
    case read_fun.(path) do
      {:ok, contents} when is_binary(contents) -> {:ok, contents}
      _ -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp optional_read(read_fun, path) do
    case read_fun.(path) do
      {:ok, contents} when is_binary(contents) -> {:ok, contents}
      {:error, :enoent} -> :missing
      :error -> :missing
      _ -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp system_value(data, key) when is_list(data), do: Keyword.get(data, key)
  defp system_value(data, key) when is_map(data), do: Map.get(data, key)
  defp system_value(_data, _key), do: nil

  defp maybe_os_mon_system_sample do
    case :os.type() do
      {:unix, :linux} -> {:error, :unavailable}
      _ -> os_mon_system_sample()
    end
  end

  defp os_mon_system_sample do
    case Application.ensure_all_started(:os_mon) do
      {:ok, _started} -> system_sample(&:memsup.get_system_memory_data/0)
      {:error, _reason} -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end
end
