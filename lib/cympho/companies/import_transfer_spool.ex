defmodule Cympho.Companies.ImportTransferSpool do
  @moduledoc """
  Confined disk spool for resumable company imports.

  Paths are derived only from server UUIDs and bounded integer positions. Raw
  request bytes are pulled through an injectable reader in 64 KiB chunks,
  hashed while writing a mode-0600 temporary file, and atomically renamed only
  after the declared byte count and SHA-256 match.
  """

  @read_bytes 64 * 1024
  @uuid_re ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i

  def read_bytes, do: @read_bytes

  def root(opts \\ []) do
    Keyword.get(opts, :spool_root) ||
      Application.get_env(
        :cympho,
        :company_import_transfer_spool_root,
        Application.get_env(
          :cympho,
          :import_transfer_spool_root,
          Path.join(System.tmp_dir!(), "cympho-company-import-transfers")
        )
      )
  end

  def prepare_root(opts \\ []) do
    root = opts |> root() |> Path.expand()

    with :ok <- reject_symlink(root),
         :ok <- File.mkdir_p(root),
         :ok <- File.chmod(root, 0o700),
         :ok <- regular_directory(root) do
      {:ok, root}
    end
  end

  def part_path(transfer_id, position, opts \\ []) do
    with {:ok, root} <- prepare_root(opts),
         {:ok, dir} <- transfer_dir(root, transfer_id),
         :ok <- validate_position(position) do
      {:ok, Path.join(dir, "part-#{position}")}
    end
  end

  @doc "Streams, verifies, and atomically installs a declared part."
  def ingest(
        transfer_id,
        position,
        expected_size,
        expected_sha256,
        reader,
        reader_state,
        opts \\ []
      )

  def ingest(
        transfer_id,
        position,
        expected_size,
        expected_sha256,
        reader,
        reader_state,
        opts
      )
      when is_function(reader, 1) do
    with {:ok, root} <- prepare_root(opts),
         {:ok, dir} <- transfer_dir(root, transfer_id),
         :ok <- validate_position(position),
         :ok <- File.mkdir_p(dir),
         :ok <- regular_directory(dir),
         :ok <- File.chmod(dir, 0o700),
         {:ok, target} <- confined_part_path(root, transfer_id, position) do
      temp = target <> ".tmp-" <> random_suffix()

      result =
        with {:ok, io} <- File.open(temp, [:write, :binary, :exclusive]),
             :ok <- File.chmod(temp, 0o600) do
          try do
            hash = :crypto.hash_init(:sha256)

            case ingest_chunks(io, reader, reader_state, expected_size, 0, hash) do
              {:ok, final_state, ^expected_size, hash_state} ->
                digest = hash_state |> :crypto.hash_final() |> Base.encode16(case: :lower)

                if Plug.Crypto.secure_compare(digest, expected_sha256) do
                  case :file.sync(io) do
                    :ok ->
                      install_verified(temp, target, final_state, opts)

                    {:error, reason} ->
                      {:error, {:spool_write_failed, reason}}
                  end
                else
                  {:error, :part_sha256_mismatch}
                end

              {:ok, _final_state, _actual_size, _hash_state} ->
                {:error, :part_size_mismatch}

              {:error, reason} ->
                {:error, reason}
            end
          after
            File.close(io)
          end
        end

      if match?({:error, _}, result), do: File.rm(temp)
      result
    end
  end

  def ingest(_id, _position, _size, _sha, _reader, _state, _opts),
    do: {:error, :invalid_reader}

  def verified_part?(transfer_id, position, expected_size, opts \\ []) do
    with {:ok, path} <- part_path(transfer_id, position, opts),
         {:ok, %File.Stat{type: :regular, size: ^expected_size}} <- File.lstat(path) do
      true
    else
      _ -> false
    end
  end

  @doc "Re-hashes a regular spooled part without retaining its bytes."
  def verify_part(transfer_id, position, expected_size, expected_sha256, opts \\ []) do
    with {:ok, path} <- part_path(transfer_id, position, opts),
         {:ok, %File.Stat{type: :regular, size: ^expected_size}} <- File.lstat(path),
         {:ok, io} <- File.open(path, [:read, :binary]) do
      try do
        case reduce_file(io, :crypto.hash_init(:sha256), &:crypto.hash_update/2) do
          {:ok, hash} ->
            digest = hash |> :crypto.hash_final() |> Base.encode16(case: :lower)

            byte_size(digest) == byte_size(expected_sha256) and
              Plug.Crypto.secure_compare(digest, expected_sha256)

          _ ->
            false
        end
      after
        File.close(io)
      end
    else
      _ -> false
    end
  end

  def remove_part(transfer_id, position, opts \\ []) do
    with {:ok, path} <- part_path(transfer_id, position, opts) do
      File.rm(path)
      |> case do
        :ok -> :ok
        {:error, :enoent} -> :ok
        error -> error
      end
    end
  end

  def remove_transfer(transfer_id, opts \\ []) do
    with {:ok, root} <- prepare_root(opts),
         {:ok, dir} <- transfer_dir(root, transfer_id) do
      case File.lstat(dir) do
        {:ok, %File.Stat{type: :directory}} ->
          case File.rm_rf(dir) do
            {:ok, _} -> :ok
            {:error, reason, _path} -> {:error, reason}
          end

        {:ok, _other} ->
          File.rm(dir)

        {:error, :enoent} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "Hashes all declared parts in order without constructing the whole input binary."
  def hash_parts(transfer_id, parts, opts \\ []) when is_list(parts) do
    hash = :crypto.hash_init(:sha256)

    with {:ok, final_hash} <-
           Enum.reduce_while(parts, {:ok, hash}, fn part, {:ok, state} ->
             case reduce_part(transfer_id, part, state, &:crypto.hash_update/2, opts) do
               {:ok, next} -> {:cont, {:ok, next}}
               {:error, reason} -> {:halt, {:error, reason}}
             end
           end) do
      {:ok, final_hash |> :crypto.hash_final() |> Base.encode16(case: :lower)}
    end
  end

  @doc "Incrementally decodes one JSON value across ordered part boundaries."
  def decode_json(transfer_id, parts, opts \\ []) when is_list(parts) do
    initial = %{decoder: :new, result: nil, trailing?: false}

    with {:ok, decoder} <-
           Enum.reduce_while(parts, {:ok, initial}, fn part, {:ok, state} ->
             case reduce_part(transfer_id, part, state, &decode_chunk/2, opts) do
               {:ok, next} -> {:cont, {:ok, next}}
               {:error, reason} -> {:halt, {:error, reason}}
             end
           end),
         {:ok, value} <- finish_decoder(decoder),
         true <- is_map(value) do
      {:ok, value}
    else
      false -> {:error, :invalid_json_package}
      {:error, _reason} = error -> error
    end
  catch
    :error, _reason -> {:error, :invalid_json}
    :exit, _reason -> {:error, :invalid_json}
    :throw, _reason -> {:error, :invalid_json}
  end

  def list_transfer_directories(opts \\ []) do
    with {:ok, root} <- prepare_root(opts),
         {:ok, entries} <- File.ls(root) do
      {:ok, Enum.filter(entries, &Regex.match?(@uuid_re, &1))}
    else
      {:error, :enoent} -> {:ok, []}
      error -> error
    end
  end

  def directory_mtime(transfer_id, opts \\ []) do
    with {:ok, root} <- prepare_root(opts),
         {:ok, dir} <- transfer_dir(root, transfer_id),
         {:ok, %File.Stat{type: :directory, mtime: mtime}} <- File.lstat(dir) do
      {:ok, mtime |> NaiveDateTime.from_erl!() |> DateTime.from_naive!("Etc/UTC")}
    else
      _ -> {:error, :not_found}
    end
  end

  defp ingest_chunks(io, reader, state, expected_size, size, hash) do
    case call_reader(reader, state) do
      {:ok, chunk, next_state} when is_binary(chunk) and byte_size(chunk) <= @read_bytes ->
        next_size = size + byte_size(chunk)

        if next_size > expected_size do
          {:error, :part_too_large}
        else
          case IO.binwrite(io, chunk) do
            :ok ->
              ingest_chunks(
                io,
                reader,
                next_state,
                expected_size,
                next_size,
                :crypto.hash_update(hash, chunk)
              )

            {:error, reason} ->
              {:error, {:spool_write_failed, reason}}
          end
        end

      {:ok, chunk, _next_state} when is_binary(chunk) ->
        {:error, :reader_chunk_too_large}

      {:ok, _not_binary, _next_state} ->
        {:error, :invalid_reader_chunk}

      :eof ->
        {:ok, state, size, hash}

      {:error, reason} ->
        {:error, {:reader_error, reason}}

      _other ->
        {:error, :invalid_reader_result}
    end
  end

  defp call_reader(reader, state) do
    reader.(state)
  rescue
    _exception -> {:error, :reader_failed}
  catch
    _kind, _reason -> {:error, :reader_failed}
  end

  defp install_verified(temp, target, final_state, opts) do
    case Keyword.get(opts, :verified_installer) do
      nil ->
        case File.rename(temp, target) do
          :ok ->
            _ = File.chmod(target, 0o600)
            {:ok, final_state}

          {:error, reason} ->
            {:error, {:spool_write_failed, reason}}
        end

      installer when is_function(installer, 2) ->
        case call_verified_installer(installer, temp, target) do
          {:ok, installed} -> {:ok, final_state, installed}
          {:error, _reason} = error -> error
          _other -> {:error, :invalid_verified_installer_result}
        end

      _invalid ->
        {:error, :invalid_verified_installer}
    end
  end

  defp call_verified_installer(installer, temp, target) do
    installer.(temp, target)
  rescue
    _exception -> {:error, :spool_install_failed}
  catch
    _kind, _reason -> {:error, :spool_install_failed}
  end

  defp reduce_part(transfer_id, part, acc, reducer, opts) do
    position = Map.fetch!(part, :position)
    expected_size = Map.fetch!(part, :byte_size)
    expected_sha256 = Map.get(part, :sha256)

    with {:ok, path} <- part_path(transfer_id, position, opts),
         {:ok, %File.Stat{type: :regular, size: ^expected_size}} <- File.lstat(path),
         {:ok, io} <- File.open(path, [:read, :binary]) do
      try do
        reduce_verified_file(
          io,
          acc,
          reducer,
          :crypto.hash_init(:sha256),
          expected_sha256,
          position
        )
      after
        File.close(io)
      end
    else
      _ -> {:error, {:missing_part, position}}
    end
  end

  defp reduce_verified_file(io, acc, reducer, hash, expected_sha256, position) do
    case IO.binread(io, @read_bytes) do
      :eof ->
        digest = hash |> :crypto.hash_final() |> Base.encode16(case: :lower)

        if is_nil(expected_sha256) or
             (byte_size(digest) == byte_size(expected_sha256) and
                Plug.Crypto.secure_compare(digest, expected_sha256)) do
          {:ok, acc}
        else
          {:error, {:part_sha256_mismatch, position}}
        end

      {:error, reason} ->
        {:error, {:spool_read_failed, reason}}

      chunk when is_binary(chunk) ->
        reduce_verified_file(
          io,
          reducer.(acc, chunk),
          reducer,
          :crypto.hash_update(hash, chunk),
          expected_sha256,
          position
        )
    end
  end

  defp reduce_file(io, acc, reducer) do
    case IO.binread(io, @read_bytes) do
      :eof -> {:ok, acc}
      {:error, reason} -> {:error, {:spool_read_failed, reason}}
      chunk when is_binary(chunk) -> reduce_file(io, reducer.(acc, chunk), reducer)
    end
  end

  defp decode_chunk(%{trailing?: true} = state, chunk) do
    if whitespace?(chunk), do: state, else: throw({:invalid_json, :trailing_data})
  end

  defp decode_chunk(%{decoder: :new} = state, chunk) do
    decode_result(:json.decode_start(chunk, :ok, %{null: nil}), state)
  end

  defp decode_chunk(%{decoder: {:continue, continuation}} = state, chunk) do
    decode_result(:json.decode_continue(chunk, continuation), state)
  end

  defp decode_result({:continue, continuation}, state),
    do: %{state | decoder: {:continue, continuation}}

  defp decode_result({result, :ok, rest}, state) do
    if whitespace?(rest) do
      %{state | decoder: :done, result: result, trailing?: true}
    else
      throw({:invalid_json, :trailing_data})
    end
  end

  defp finish_decoder(%{decoder: :done, result: result}), do: {:ok, result}

  defp finish_decoder(%{decoder: {:continue, continuation}}) do
    case :json.decode_continue(:end_of_input, continuation) do
      {result, :ok, rest} ->
        if whitespace?(rest), do: {:ok, result}, else: {:error, :invalid_json}

      {:continue, _state} ->
        {:error, :invalid_json}
    end
  catch
    :error, _reason -> {:error, :invalid_json}
  end

  defp finish_decoder(_state), do: {:error, :invalid_json}

  defp whitespace?(binary), do: String.trim(binary) == ""

  defp transfer_dir(root, transfer_id) when is_binary(transfer_id) do
    if Regex.match?(@uuid_re, transfer_id) do
      dir = Path.expand(Path.join(root, transfer_id))

      if confined?(root, dir) do
        case File.lstat(dir) do
          {:ok, %File.Stat{type: :directory}} -> {:ok, dir}
          {:error, :enoent} -> {:ok, dir}
          {:ok, _other} -> {:error, :unsafe_transfer_directory}
          {:error, reason} -> {:error, reason}
        end
      else
        {:error, :invalid_transfer_id}
      end
    else
      {:error, :invalid_transfer_id}
    end
  end

  defp transfer_dir(_root, _transfer_id), do: {:error, :invalid_transfer_id}

  defp confined_part_path(root, transfer_id, position) do
    with {:ok, dir} <- transfer_dir(root, transfer_id) do
      path = Path.expand(Path.join(dir, "part-#{position}"))
      if confined?(root, path), do: {:ok, path}, else: {:error, :invalid_part_path}
    end
  end

  defp confined?(root, path) do
    relative = Path.relative_to(path, root)
    relative != path and relative != ".." and not String.starts_with?(relative, "../")
  end

  defp validate_position(position)
       when is_integer(position) and position >= 0 and position < 4096,
       do: :ok

  defp validate_position(_position), do: {:error, :invalid_part_position}

  defp reject_symlink(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} -> {:error, :unsafe_spool_root}
      {:ok, _} -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp regular_directory(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      {:ok, _} -> {:error, :unsafe_spool_path}
      {:error, reason} -> {:error, reason}
    end
  end

  defp random_suffix, do: :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
end
