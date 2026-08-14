defmodule Cympho.Companies.PackageSource do
  @moduledoc """
  Portable company packages as a documented directory format, plus loading one
  from a ref-pinned repository.

  ## Directory format

  A package directory contains a manifest and one JSON file per collection:

      my-company-package/
        cympho-package.json     # manifest
        company.json
        users.json
        memberships.json
        projects.json
        agents.json
        issues.json
        goals.json
        labels.json
        secret_manifest.json

  The manifest declares the format, the package version, and which collection
  files are present:

      {
        "format": "cympho.company.package",
        "version": 1,
        "exported_at": "2026-08-14T12:00:00Z",
        "files": {"company": "company.json", "agents": "agents.json"}
      }

  A manifest may only name files from `collection_files/0`; anything else is
  rejected, so a hostile manifest cannot direct the loader at an arbitrary path.
  Entries are read with `File.lstat/1` first and symlinks are refused, and every
  resolved path must stay inside the package root.

  Packages never contain secret values — `Cympho.Companies.export_company/1`
  redacts them before they reach a writer here, and `secret_manifest.json` holds
  only the restore checklist.

  ## Repository sources

  `load_github/2` fetches a package from `raw.githubusercontent.com` at a pinned
  commit. A 40-character commit SHA is required: branch and tag names move, so a
  package fetched from one would not be reproducible. Passing
  `allow_unpinned: true` accepts a branch or tag for development.
  """

  require Logger

  @manifest_file "cympho-package.json"
  @format "cympho.company.package"
  @supported_versions [1]

  @collection_files %{
    company: "company.json",
    users: "users.json",
    memberships: "memberships.json",
    projects: "projects.json",
    agents: "agents.json",
    issues: "issues.json",
    goals: "goals.json",
    labels: "labels.json",
    secret_manifest: "secret_manifest.json"
  }

  @metadata_keys [:version, :exported_at, :format]

  @max_file_bytes 10 * 1024 * 1024
  @max_total_bytes 50 * 1024 * 1024

  @repo_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\/[A-Za-z0-9][A-Za-z0-9._-]*\z/
  @sha_pattern ~r/\A[0-9a-f]{40}\z/
  @loose_ref_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9._\/-]{0,254}\z/
  @path_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9._\/-]{0,254}\z/

  @default_base_url "https://raw.githubusercontent.com"
  @request_timeout 15_000

  @doc "Manifest filename inside a package directory."
  def manifest_file, do: @manifest_file

  @doc "Format identifier written into and required by the manifest."
  def format, do: @format

  @doc "Collection key to filename mapping for the directory format."
  def collection_files, do: @collection_files

  # --- Writing ----------------------------------------------------------------

  @doc """
  Writes a package map to `path` in the documented directory format.

  Only collections present in the package are written, and the manifest lists
  exactly those files so a selective export round-trips.
  """
  @spec write_dir(map(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def write_dir(package, path) when is_map(package) and is_binary(path) do
    with {:ok, root} <- ensure_writable_root(path) do
      files =
        Enum.reduce(@collection_files, %{}, fn {key, filename}, acc ->
          case fetch(package, key) do
            :error ->
              acc

            {:ok, value} ->
              File.write!(Path.join(root, filename), Jason.encode!(value))
              Map.put(acc, Atom.to_string(key), filename)
          end
        end)

      manifest = %{
        "format" => @format,
        "version" => fetch(package, :version) |> unwrap(1),
        "exported_at" => fetch(package, :exported_at) |> unwrap(nil),
        "files" => files
      }

      File.write!(Path.join(root, @manifest_file), Jason.encode!(manifest))
      {:ok, root}
    end
  rescue
    error in [File.Error, Jason.EncodeError] -> {:error, Exception.message(error)}
  end

  def write_dir(_package, _path), do: {:error, "Package and path are required."}

  # --- Local directory --------------------------------------------------------

  @doc """
  Loads a package from a directory in the documented format.
  """
  @spec load_dir(String.t()) :: {:ok, map()} | {:error, term()}
  def load_dir(path) when is_binary(path) do
    with {:ok, root} <- ensure_readable_root(path),
         {:ok, manifest} <- read_json_file(root, @manifest_file),
         {:ok, files} <- validate_manifest(manifest) do
      Enum.reduce_while(files, {:ok, metadata(manifest)}, fn {key, filename}, {:ok, acc} ->
        case read_json_file(root, filename) do
          {:ok, value} -> {:cont, {:ok, Map.put(acc, Atom.to_string(key), value)}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  def load_dir(_path), do: {:error, "Package directory path must be a binary."}

  # --- Repository -------------------------------------------------------------

  @doc """
  Loads a package from a GitHub repository at a pinned commit.

  Options:
  * `:ref` — required; a 40-character commit SHA unless `:allow_unpinned`
  * `:path` — file or directory inside the repo, default `cympho-package.json`
  * `:allow_unpinned` — accept a branch or tag (development only)
  * `:token` — bearer token for private repositories; never logged
  """
  @spec load_github(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def load_github(repo, opts \\ [])

  def load_github(repo, opts) when is_binary(repo) and is_list(opts) do
    path = Keyword.get(opts, :path, @manifest_file)

    with :ok <- validate_repo(repo),
         {:ok, ref} <- validate_ref(Keyword.get(opts, :ref), Keyword.get(opts, :allow_unpinned)),
         :ok <- validate_repo_path(path) do
      if String.ends_with?(path, ".json") and Path.basename(path) != @manifest_file do
        fetch_single_file(repo, ref, path, opts)
      else
        fetch_manifest_package(repo, ref, path, opts)
      end
    end
  end

  def load_github(_repo, _opts), do: {:error, "Repository must be given as \"owner/name\"."}

  defp fetch_single_file(repo, ref, path, opts) do
    with {:ok, body} <- get(repo, ref, path, opts) do
      decode_object(body, path)
    end
  end

  defp fetch_manifest_package(repo, ref, path, opts) do
    dir = if String.ends_with?(path, ".json"), do: Path.dirname(path), else: path
    manifest_path = join_repo_path(dir, @manifest_file)

    with {:ok, body} <- get(repo, ref, manifest_path, opts),
         {:ok, manifest} <- decode_object(body, manifest_path),
         {:ok, files} <- validate_manifest(manifest) do
      Enum.reduce_while(files, {:ok, metadata(manifest)}, fn {key, filename}, {:ok, acc} ->
        file_path = join_repo_path(dir, filename)

        with {:ok, body} <- get(repo, ref, file_path, opts),
             {:ok, value} <- decode_value(body, file_path) do
          {:cont, {:ok, Map.put(acc, Atom.to_string(key), value)}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp join_repo_path(".", filename), do: filename
  defp join_repo_path("", filename), do: filename
  defp join_repo_path(dir, filename), do: String.trim_trailing(dir, "/") <> "/" <> filename

  defp get(repo, ref, path, opts) do
    url = "#{base_url()}/#{repo}/#{ref}/#{path}"

    headers =
      case Keyword.get(opts, :token) do
        token when is_binary(token) and token != "" -> [{"authorization", "Bearer " <> token}]
        _ -> []
      end

    :get
    |> Finch.build(url, [{"accept", "application/json"} | headers])
    |> Finch.request(Cympho.Finch, receive_timeout: @request_timeout)
    |> handle_response(repo, path)
  end

  defp handle_response({:ok, %Finch.Response{status: 200, body: body}}, _repo, path) do
    if byte_size(body) > @max_file_bytes do
      {:error, "Package file #{path} exceeds the #{@max_file_bytes} byte limit."}
    else
      {:ok, body}
    end
  end

  defp handle_response({:ok, %Finch.Response{status: 404}}, repo, path) do
    {:error, "Package file #{path} was not found in #{repo} at the requested ref."}
  end

  defp handle_response({:ok, %Finch.Response{status: status}}, repo, path)
       when status in [301, 302, 303, 307, 308] do
    # A redirect off raw.githubusercontent could point anywhere; do not follow it.
    Logger.warning("package source refused a redirect",
      component: "PackageSource",
      repo: repo,
      path: path
    )

    {:error, "Package source refused a redirect for #{path}."}
  end

  defp handle_response({:ok, %Finch.Response{status: status}}, _repo, path) do
    {:error, "Package source returned HTTP #{status} for #{path}."}
  end

  defp handle_response({:error, _reason}, _repo, path) do
    # Transport errors can embed request details; keep the message generic.
    {:error, "Package source request failed for #{path}."}
  end

  defp base_url do
    Application.get_env(:cympho, :package_source_base_url, @default_base_url)
  end

  # --- Validation -------------------------------------------------------------

  defp validate_repo(repo) do
    cond do
      not Regex.match?(@repo_pattern, repo) ->
        {:error, "Repository must look like \"owner/name\"."}

      String.contains?(repo, "..") ->
        {:error, "Repository must not contain path traversal."}

      true ->
        :ok
    end
  end

  defp validate_ref(nil, _allow_unpinned) do
    {:error, "A ref is required. Pin the package to a 40-character commit SHA."}
  end

  defp validate_ref(ref, allow_unpinned) when is_binary(ref) do
    cond do
      Regex.match?(@sha_pattern, ref) ->
        {:ok, ref}

      allow_unpinned != true ->
        {:error,
         "Ref #{ref} is not a pinned commit SHA. Pass allow_unpinned: true to accept a moving branch or tag."}

      String.contains?(ref, "..") ->
        {:error, "Ref must not contain path traversal."}

      Regex.match?(@loose_ref_pattern, ref) ->
        {:ok, ref}

      true ->
        {:error, "Ref contains unsupported characters."}
    end
  end

  defp validate_ref(_ref, _allow_unpinned), do: {:error, "Ref must be a binary."}

  defp validate_repo_path(path) when is_binary(path) do
    cond do
      not Regex.match?(@path_pattern, path) ->
        {:error, "Package path contains unsupported characters."}

      String.contains?(path, "..") ->
        {:error, "Package path must not contain path traversal."}

      String.contains?(path, "//") ->
        {:error, "Package path must not contain empty segments."}

      true ->
        :ok
    end
  end

  defp validate_repo_path(_path), do: {:error, "Package path must be a binary."}

  defp validate_manifest(manifest) when is_map(manifest) do
    with :ok <- validate_manifest_format(manifest),
         :ok <- validate_manifest_version(manifest) do
      validate_manifest_files(Map.get(manifest, "files") || Map.get(manifest, :files))
    end
  end

  defp validate_manifest(_manifest), do: {:error, "Package manifest must be a JSON object."}

  defp validate_manifest_format(manifest) do
    case Map.get(manifest, "format") || Map.get(manifest, :format) do
      @format -> :ok
      nil -> {:error, "Package manifest is missing its format field."}
      other -> {:error, "Unsupported package format: #{inspect(other)}."}
    end
  end

  defp validate_manifest_version(manifest) do
    case Map.get(manifest, "version") || Map.get(manifest, :version) do
      version when version in @supported_versions -> :ok
      other -> {:error, "Unsupported package version: #{inspect(other)}."}
    end
  end

  defp validate_manifest_files(files) when is_map(files) and map_size(files) > 0 do
    Enum.reduce_while(files, {:ok, []}, fn {key, filename}, {:ok, acc} ->
      collection = known_collection(key)

      cond do
        is_nil(collection) ->
          {:halt, {:error, "Package manifest names an unknown collection: #{inspect(key)}."}}

        filename != Map.fetch!(@collection_files, collection) ->
          # The manifest may say which collections exist, never where they live.
          {:halt,
           {:error,
            "Package manifest must use the standard filename for #{key}: " <>
              Map.fetch!(@collection_files, collection) <> "."}}

        true ->
          {:cont, {:ok, [{collection, filename} | acc]}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  defp validate_manifest_files(_files),
    do: {:error, "Package manifest lists no collection files."}

  defp known_collection(key) do
    normalized = to_string(key)
    Enum.find(Map.keys(@collection_files), &(Atom.to_string(&1) == normalized))
  end

  defp metadata(manifest) do
    Enum.reduce(@metadata_keys, %{}, fn key, acc ->
      case Map.get(manifest, Atom.to_string(key)) || Map.get(manifest, key) do
        nil -> acc
        value -> Map.put(acc, Atom.to_string(key), value)
      end
    end)
  end

  # --- Filesystem -------------------------------------------------------------

  defp ensure_writable_root(path) do
    root = Path.expand(path)

    case File.mkdir_p(root) do
      :ok -> {:ok, root}
      {:error, reason} -> {:error, "Unable to create package directory: #{inspect(reason)}."}
    end
  end

  defp ensure_readable_root(path) do
    cond do
      path == "" ->
        {:error, "Package directory path must not be empty."}

      String.contains?(path, "\0") ->
        {:error, "Package directory path must not contain null bytes."}

      true ->
        root = Path.expand(path)

        cond do
          not File.exists?(root) -> {:error, "Package directory not found."}
          not File.dir?(root) -> {:error, "Package source must be a directory."}
          true -> {:ok, root}
        end
    end
  end

  defp read_json_file(root, filename) do
    with {:ok, path} <- safe_path(root, filename),
         {:ok, content} <- read_capped(path, filename) do
      decode_value(content, filename)
    end
  end

  defp safe_path(root, filename) do
    path = Path.join(root, filename)
    expanded = Path.expand(path)

    cond do
      not String.starts_with?(expanded, root <> "/") ->
        {:error, "Package file #{filename} resolves outside the package directory."}

      true ->
        case File.lstat(expanded) do
          {:ok, %File.Stat{type: :symlink}} ->
            {:error, "Package file #{filename} is a symlink, which is not allowed."}

          {:ok, %File.Stat{type: :regular, size: size}} when size > @max_file_bytes ->
            {:error, "Package file #{filename} exceeds the #{@max_file_bytes} byte limit."}

          {:ok, %File.Stat{type: :regular}} ->
            {:ok, expanded}

          {:ok, %File.Stat{}} ->
            {:error, "Package file #{filename} is not a regular file."}

          {:error, :enoent} ->
            {:error, "Package file #{filename} is missing."}

          {:error, reason} ->
            {:error, "Unable to read #{filename}: #{inspect(reason)}."}
        end
    end
  end

  defp read_capped(path, filename) do
    case File.read(path) do
      {:ok, content} when byte_size(content) <= @max_total_bytes ->
        {:ok, content}

      {:ok, _content} ->
        {:error, "Package file #{filename} exceeds the #{@max_total_bytes} byte limit."}

      {:error, reason} ->
        {:error, "Unable to read #{filename}: #{inspect(reason)}."}
    end
  end

  defp decode_object(content, filename) do
    case decode_value(content, filename) do
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, _value} -> {:error, "Package file #{filename} must contain a JSON object."}
      error -> error
    end
  end

  defp decode_value(content, filename) do
    case Jason.decode(content) do
      {:ok, value} -> {:ok, value}
      {:error, %Jason.DecodeError{}} -> {:error, "Package file #{filename} is not valid JSON."}
    end
  end

  defp fetch(package, key) do
    case Map.fetch(package, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(package, Atom.to_string(key))
    end
  end

  defp unwrap({:ok, value}, _default), do: value
  defp unwrap(:error, default), do: default
end
