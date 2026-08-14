defmodule Cympho.Companies.PortablePackage do
  @moduledoc """
  Facade for portable company packages.

  Whole-package import through `Cympho.Companies` always creates a new company
  and resolves a slug collision with `:suffix` or `:fail`.

  Merging a package into an *existing* company goes through
  `Cympho.Companies.PackageMerge`, where `:skip`, `:replace`, and `:rename`
  decide what happens to each record that already exists.

  Packages load from a decoded map, a JSON binary, a local JSON file, a
  directory in the documented format (`Cympho.Companies.PackageSource`), or a
  ref-pinned GitHub repository.
  """

  alias Cympho.Companies
  alias Cympho.Companies.PackageMerge
  alias Cympho.Companies.PackageSource
  alias Cympho.Companies.Portability

  @collision_modes [:suffix, :fail, :skip, :replace, :rename]
  @source_kinds [:json, :path, :dir, :github]

  @doc """
  Collision modes accepted by package import/preview.

  `:suffix` and `:fail` apply to the company slug when importing a package as a
  new company. `:skip`, `:replace`, and `:rename` apply per record when merging
  a package into an existing company — see `merge/3`.
  """
  def collision_modes, do: @collision_modes

  @doc """
  Supported package source kinds for `load_source/2`.
  """
  def source_kinds, do: @source_kinds

  @doc """
  Exports a company package.

  Options:
  - `:includes` — `:all` (default) or a list of collection keys. Selective
    filtering is applied after the whole-package export so V1 data remains the
    source of truth.
  """
  def export(company_id, opts \\ [])

  def export(company_id, opts) when is_binary(company_id) and is_list(opts) do
    includes = Portability.normalize_includes(Keyword.get(opts, :includes, :all))

    package =
      company_id
      |> Companies.export_company()
      |> Portability.apply_includes(includes)

    {:ok, package}
  rescue
    Ecto.NoResultsError -> {:error, "Company not found."}
  end

  def export(_company_id, _opts), do: {:error, "Company id must be a binary id."}

  @doc """
  Read-only import preview. Accepts a decoded package map, JSON binary, or
  `{:json, _}` / `{:path, _}` source tuple.
  """
  def preview(source, opts \\ [])

  def preview(source, opts) when is_list(opts) do
    with {:ok, data} <- resolve_source(source) do
      Portability.preview_import(data, opts)
    end
  end

  @doc """
  Imports a package. Accepts the same sources as `preview/2`.
  """
  def import(source, opts \\ [])

  def import(source, opts) when is_list(opts) do
    with {:ok, data} <- resolve_source(source) do
      Companies.import_company(data, opts)
    end
  end

  @doc """
  Exports a company into a directory in the documented package format.

  Accepts the same `:includes` option as `export/2`.
  """
  def export_dir(company_id, path, opts \\ []) do
    with {:ok, package} <- export(company_id, opts) do
      PackageSource.write_dir(package, path)
    end
  end

  @doc """
  Dry-run merge of a package into an existing company. Writes nothing.

  Options: `:collision` (`:skip` default, `:replace`, `:rename`, `:fail`) and
  `:includes`.
  """
  def merge_preview(source, company_id, opts \\ []) do
    with {:ok, data} <- resolve_source(source) do
      PackageMerge.preview(data, company_id, opts)
    end
  end

  @doc """
  Merges a package into an existing company using the plan from `merge_preview/3`.
  """
  def merge(source, company_id, opts \\ []) do
    with {:ok, data} <- resolve_source(source) do
      PackageMerge.apply(data, company_id, opts)
    end
  end

  @doc """
  Loads a package from a typed source.

  - `load_source(:json, binary | map)` — decode JSON or accept an already-decoded map
  - `load_source(:path, path)` — read a local JSON file (fail-closed path checks)
  - `load_source(:dir, path)` — read a directory in the documented package format
  - `load_source(:github, {repo, opts})` — fetch from a ref-pinned repository
  """
  def load_source(kind, source)

  def load_source(:json, data) when is_map(data), do: {:ok, data}

  def load_source(:json, content) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, data} when is_map(data) ->
        {:ok, data}

      {:ok, _other} ->
        {:error, "Import package must be a JSON object."}

      {:error, %Jason.DecodeError{}} ->
        {:error, "Invalid JSON package."}
    end
  end

  def load_source(:json, _content), do: {:error, "JSON source must be a binary or map."}

  def load_source(:path, path) when is_binary(path) do
    with :ok <- validate_readable_path(path),
         {:ok, content} <- File.read(path) do
      load_source(:json, content)
    else
      {:error, :enoent} ->
        {:error, "Package path not found."}

      {:error, :eacces} ->
        {:error, "Package path is not readable."}

      {:error, :eisdir} ->
        {:error, "Package path must be a file."}

      {:error, message} when is_binary(message) ->
        {:error, message}

      {:error, _reason} ->
        {:error, "Unable to read package path."}
    end
  end

  def load_source(:path, _path), do: {:error, "Path source must be a binary path."}

  def load_source(:dir, path), do: PackageSource.load_dir(path)

  def load_source(:github, {repo, opts}) when is_binary(repo) and is_list(opts),
    do: PackageSource.load_github(repo, opts)

  def load_source(:github, repo) when is_binary(repo), do: PackageSource.load_github(repo, [])

  def load_source(:github, _source),
    do: {:error, "GitHub source must be a repository binary or {repo, opts}."}

  def load_source(kind, _source) do
    {:error,
     "Unsupported package source kind: #{inspect(kind)}. Use :json, :path, :dir, or :github."}
  end

  defp resolve_source(data) when is_map(data), do: {:ok, data}
  defp resolve_source(content) when is_binary(content), do: load_source(:json, content)
  defp resolve_source({:json, content}), do: load_source(:json, content)
  defp resolve_source({:path, path}), do: load_source(:path, path)
  defp resolve_source({:dir, path}), do: load_source(:dir, path)
  defp resolve_source({:github, source}), do: load_source(:github, source)
  defp resolve_source(_source), do: {:error, "Unsupported package source."}

  defp validate_readable_path(path) do
    cond do
      path == "" ->
        {:error, "Package path must not be empty."}

      String.contains?(path, "\0") ->
        {:error, "Package path must not contain null bytes."}

      true ->
        expanded = Path.expand(path)

        cond do
          not File.exists?(expanded) ->
            {:error, :enoent}

          File.dir?(expanded) ->
            {:error, :eisdir}

          true ->
            :ok
        end
    end
  end
end
