defmodule Cympho.Companies.ImportTransfers do
  @moduledoc """
  Durable, resumable transport for V1 company JSON imports.

  Upload and verification are bounded to 64 KiB raw chunks and never assemble
  the source JSON in memory. `decode/3` uses OTP's incremental JSON decoder,
  but its result is still the complete decoded package map because the current
  portability validator and importer consume that representation. The default
  50 MB input cap therefore bounds, but does not eliminate, decoded-map memory.
  """

  import Ecto.Query, warn: false

  alias Cympho.Companies.ImportTransfer
  alias Cympho.Companies.ImportTransferPart
  alias Cympho.Companies.ImportTransferSpool
  alias Cympho.Repo

  @default_max_total_bytes 50_000_000
  @default_max_part_bytes 4 * 1024 * 1024
  @max_parts 4096
  @default_max_age_ms 24 * 60 * 60 * 1000
  @default_apply_lease_ms 30 * 60 * 1000
  @default_upload_lease_ms 10 * 60 * 1000
  @default_max_actor_open 3
  @default_max_actor_bytes 100_000_000
  @default_max_global_open 20
  @default_max_global_bytes 250_000_000
  @default_max_applying 1
  @default_max_package_records 25_000
  @default_max_planned_writes 25_000
  @default_max_secret_receipt_entries 5_000
  @default_max_secret_receipt_bytes 1_000_000
  @secret_receipt_binary_limits %{
    key: 255,
    scope: 32,
    scope_id: 64,
    original_scope_id: 64,
    description: 1_000,
    restore_status: 64
  }
  @sha_re ~r/\A[0-9a-f]{64}\z/
  @idempotency_re ~r/\A[A-Za-z0-9_-]{16,128}\z/
  @open_upload_statuses ~w(pending uploading ready failed)
  @cancel_statuses ~w(pending uploading ready failed)

  def default_max_total_bytes, do: @default_max_total_bytes
  def default_max_part_bytes, do: @default_max_part_bytes
  def max_parts, do: @max_parts

  def max_total_bytes(opts \\ []) do
    positive_limit(
      Keyword.get(
        opts,
        :max_total_bytes,
        Application.get_env(
          :cympho,
          :company_import_transfer_max_bytes,
          @default_max_total_bytes
        )
      ),
      @default_max_total_bytes
    )
  end

  def max_part_bytes(opts \\ []) do
    positive_limit(
      Keyword.get(
        opts,
        :max_part_bytes,
        Application.get_env(
          :cympho,
          :company_import_transfer_max_part_bytes,
          @default_max_part_bytes
        )
      ),
      @default_max_part_bytes
    )
  end

  def admission_limits(opts \\ []) do
    %{
      actor_open:
        limit(
          opts,
          :max_actor_open,
          :company_import_transfer_max_actor_open,
          @default_max_actor_open
        ),
      actor_bytes:
        limit(
          opts,
          :max_actor_bytes,
          :company_import_transfer_max_actor_bytes,
          @default_max_actor_bytes
        ),
      global_open:
        limit(
          opts,
          :max_global_open,
          :company_import_transfer_max_global_open,
          @default_max_global_open
        ),
      global_bytes:
        limit(
          opts,
          :max_global_bytes,
          :company_import_transfer_max_global_bytes,
          @default_max_global_bytes
        ),
      applying:
        limit(opts, :max_applying, :company_import_transfer_max_applying, @default_max_applying)
    }
  end

  def apply_limits(opts \\ []) do
    %{
      package_records:
        limit(
          opts,
          :max_package_records,
          :company_import_transfer_max_package_records,
          @default_max_package_records
        ),
      planned_writes:
        limit(
          opts,
          :max_planned_writes,
          :company_import_transfer_max_planned_writes,
          @default_max_planned_writes
        ),
      secret_receipt_entries:
        limit(
          opts,
          :max_secret_receipt_entries,
          :company_import_transfer_max_secret_receipt_entries,
          @default_max_secret_receipt_entries
        ),
      secret_receipt_bytes:
        limit(
          opts,
          :max_secret_receipt_bytes,
          :company_import_transfer_max_secret_receipt_bytes,
          @default_max_secret_receipt_bytes
        )
    }
  end

  @doc "Rejects a validated import plan whose record or write count exceeds configured bounds."
  def validate_apply_capacity(preview, opts \\ [])

  def validate_apply_capacity(%{inventory: inventory} = preview, opts) when is_map(inventory) do
    limits = apply_limits(opts)
    package_records = map_integer(inventory, :package_records)
    planned_writes = map_integer(inventory, :planned_writes)
    receipt_entries = map_integer(inventory, :secret_restore_requirements)
    receipt = Map.get(preview, :secret_restore_requirements, [])

    cond do
      is_nil(package_records) or is_nil(planned_writes) or is_nil(receipt_entries) ->
        {:error, :invalid_json_package}

      package_records > limits.package_records or planned_writes > limits.planned_writes or
        receipt_entries > limits.secret_receipt_entries or
          encoded_size(receipt) > limits.secret_receipt_bytes ->
        {:error, :package_capacity_exceeded}

      true ->
        :ok
    end
  end

  def validate_apply_capacity(_preview, _opts), do: {:error, :invalid_json_package}

  @doc "Declares a transfer or resumes the actor's matching active declaration."
  def declare(owner_user_id, manifest, opts \\ [])

  def declare(owner_user_id, manifest, opts) when is_binary(owner_user_id) do
    with {:ok, declaration} <- normalize_manifest(manifest, opts),
         :ok <- authorize_target(owner_user_id, declaration.target_company_id),
         {:ok, transfer, resumed} <- declare_locked(owner_user_id, declaration, opts),
         {:ok, result} <- status(transfer.id, owner_user_id, opts) do
      {:ok,
       result
       |> Map.put(:resumed, resumed)
       |> Map.put(:already_completed, transfer.status == "completed")}
    end
  end

  def declare(_owner_user_id, _manifest, _opts), do: {:error, :invalid_manifest}

  @doc "Performs an actor-scoped O(1) existence check without touching spool parts."
  def authorize(transfer_id, owner_user_id) do
    with {:ok, id} <- Ecto.UUID.cast(transfer_id),
         %ImportTransfer{} = transfer <-
           Repo.one(
             from(t in ImportTransfer,
               where: t.id == ^id and t.owner_user_id == ^owner_user_id
             )
           ) do
      {:ok, transfer}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Returns actor-scoped progress after reconciling missing spool files."
  def status(transfer_id, owner_user_id, opts \\ []) do
    with {:ok, transfer} <- fetch_for_owner(transfer_id, owner_user_id),
         {:ok, transfer} <- reconcile_missing_files(transfer, opts) do
      parts = ordered_parts(transfer)

      {uploaded, missing} =
        if transfer.status == "completed" do
          {Enum.map(parts, & &1.position), []}
        else
          Enum.reduce(parts, {[], []}, fn part, {done, absent} ->
            if part.uploaded_at &&
                 ImportTransferSpool.verify_part(
                   transfer.id,
                   part.position,
                   part.byte_size,
                   part.sha256,
                   opts
                 ) do
              {[part.position | done], absent}
            else
              {done, [part.position | absent]}
            end
          end)
          |> then(fn {done, absent} -> {Enum.reverse(done), Enum.reverse(absent)} end)
        end

      {:ok,
       %{
         transfer: transfer,
         total_parts: transfer.part_count,
         uploaded_parts: length(uploaded),
         uploaded_positions: uploaded,
         missing_parts: missing,
         already_completed: transfer.status == "completed"
       }}
    end
  end

  @doc "Streams one raw part from `reader.(state)` and records it after verification."
  def put_part_from_reader(transfer_id, owner_user_id, position, reader, opts \\ [])

  def put_part_from_reader(
        transfer_id,
        owner_user_id,
        position,
        reader,
        opts
      )
      when is_integer(position) and is_function(reader, 1) and is_list(opts) do
    initial_state = Keyword.get(opts, :reader_state)

    with {:ok, transfer} <- fetch_for_owner(transfer_id, owner_user_id),
         {:ok, part} <- declared_part(transfer, position),
         :ok <- uploadable(transfer),
         {:continue, already_completed} <- completed_part_result(transfer, part, opts) do
      case already_completed do
        true ->
          {:ok,
           %{
             index: position,
             already_completed: true,
             transfer: transfer,
             reader_state: initial_state
           }}

        false ->
          put_claimed_part(transfer, part, owner_user_id, reader, initial_state, opts)
      end
    end
  end

  def put_part_from_reader(_id, _owner, _position, _reader, _opts),
    do: {:error, :invalid_part}

  @doc "Verifies the whole stream hash and incrementally decodes the V1 JSON map."
  def decode(transfer_id, owner_user_id, opts \\ []) do
    with {:ok, transfer} <- fetch_for_owner(transfer_id, owner_user_id),
         :ok <- decodable_transfer(transfer),
         parts = part_descriptors(transfer),
         {:ok, digest} <- ImportTransferSpool.hash_parts(transfer_id, parts, opts),
         :ok <- matching_file_hash(digest, transfer.file_sha256),
         {:ok, package} <- ImportTransferSpool.decode_json(transfer_id, parts, opts) do
      {:ok, package}
    else
      {:error, {:missing_part, _position}} -> {:error, :missing_parts}
      {:error, {:part_sha256_mismatch, _position}} -> {:error, :integrity_error}
      error -> error
    end
  end

  def decode_package(transfer_id, owner_user_id, opts \\ []),
    do: decode(transfer_id, owner_user_id, opts)

  @doc "Atomically lets exactly one ready caller enter the applying state."
  def claim_apply(transfer_id, owner_user_id, opts \\ []) do
    Repo.transaction(fn ->
      Repo.query!(
        "SELECT pg_advisory_xact_lock(hashtextextended('company-import-apply-capacity', 0))"
      )

      case locked_transfer(transfer_id, owner_user_id) do
        nil ->
          Repo.rollback(:not_found)

        %ImportTransfer{} = transfer ->
          missing = missing_part_count(transfer.id)
          now_value = Keyword.get(opts, :now, now())

          claimable? =
            transfer.status in ["ready", "failed"] or
              (transfer.status == "applying" and
                 not is_nil(transfer.apply_lease_expires_at) and
                 DateTime.compare(transfer.apply_lease_expires_at, now_value) == :lt)

          applying_count =
            Repo.aggregate(
              from(t in ImportTransfer,
                where:
                  t.status == "applying" and t.id != ^transfer.id and
                    t.apply_lease_expires_at > ^now_value
              ),
              :count
            )

          cond do
            not claimable? ->
              Repo.rollback(if(transfer.status == "completed", do: :conflict, else: :not_ready))

            missing != 0 ->
              Repo.rollback(:not_ready)

            not target_authorized?(owner_user_id, transfer.target_company_id) ->
              Repo.rollback(:not_found)

            applying_count >= admission_limits(opts).applying ->
              Repo.rollback(:capacity_exceeded)

            true ->
              token = random_token()

              transfer =
                transfer
                |> Ecto.Changeset.change(
                  status: "applying",
                  error: nil,
                  apply_started_at: now_value,
                  apply_claim_token: token,
                  apply_lease_expires_at:
                    DateTime.add(
                      now_value,
                      apply_lease_ms(opts),
                      :millisecond
                    ),
                  updated_at: now_value
                )
                |> Repo.update!()

              transfer
          end
      end
    end)
    |> transaction_result()
  end

  @doc "Settles an applying transfer. Import code should eventually call this in its DB transaction."
  def complete(
        transfer_id,
        owner_user_id,
        claim_token,
        imported_company_id \\ nil,
        secrets_to_restore \\ []
      ) do
    transition(transfer_id, owner_user_id, ["applying"], fn transfer ->
      if not secure_token?(transfer.apply_claim_token, claim_token), do: Repo.rollback(:conflict)
      now = now()

      transfer
      |> Ecto.Changeset.change(
        status: "completed",
        error: nil,
        imported_company_id: imported_company_id,
        secrets_to_restore: normalize_secret_receipt(secrets_to_restore),
        apply_claim_token: nil,
        apply_lease_expires_at: nil,
        completed_at: now,
        updated_at: now
      )
      |> Repo.update!()
    end)
  end

  @doc """
  Completes a transfer through the caller's current database transaction.

  `repo` is injectable for transaction tests. A guarded miss returns an error
  so the enclosing company import can roll back instead of committing without
  its exactly-once transfer marker.
  """
  def complete_in_transaction(
        repo,
        transfer_id,
        owner_user_id,
        claim_token,
        imported_company_id \\ nil,
        secrets_to_restore \\ []
      ) do
    now_value = now()

    {count, _} =
      repo.update_all(
        from(t in ImportTransfer,
          where:
            t.id == ^transfer_id and t.owner_user_id == ^owner_user_id and
              t.status == "applying" and t.apply_claim_token == ^claim_token
        ),
        set: [
          status: "completed",
          error: nil,
          imported_company_id: imported_company_id,
          secrets_to_restore: normalize_secret_receipt(secrets_to_restore),
          apply_claim_token: nil,
          apply_lease_expires_at: nil,
          completed_at: now_value,
          updated_at: now_value
        ]
      )

    if count == 1, do: :ok, else: {:error, :conflict}
  end

  @doc "Releases an applying claim to a retryable failed state."
  def fail(transfer_id, owner_user_id, claim_token, reason) do
    transition(transfer_id, owner_user_id, ["applying"], fn transfer ->
      if not secure_token?(transfer.apply_claim_token, claim_token), do: Repo.rollback(:conflict)

      transfer
      |> Ecto.Changeset.change(
        status: "failed",
        error: safe_error(reason),
        apply_claim_token: nil,
        apply_lease_expires_at: nil,
        updated_at: now()
      )
      |> Repo.update!()
    end)
  end

  @doc "Cancels an open actor-owned transfer before deleting its spool."
  def cancel(transfer_id, owner_user_id, opts \\ []) do
    with {:ok, transfer} <-
           transition(transfer_id, owner_user_id, @cancel_statuses, fn transfer ->
             transfer
             |> Ecto.Changeset.change(
               status: "cancelled",
               error: nil,
               completed_at: now(),
               updated_at: now()
             )
             |> Repo.update!()
           end) do
      _ = ImportTransferSpool.remove_transfer(transfer.id, opts)
      {:ok, transfer}
    end
  end

  @doc """
  Best-effort removal of a durably completed actor-owned transfer spool.

  Filesystem cleanup is deliberately outside the company import transaction:
  once the ledger is completed, a cleanup failure must never make that
  committed import look failed or retryable. The hourly sweeper remains the
  fallback for any directory this call cannot remove.
  """
  def cleanup_completed_spool(transfer_id, owner_user_id, opts \\ []) do
    with {:ok, %ImportTransfer{status: "completed"}} <- authorize(transfer_id, owner_user_id) do
      remover =
        Keyword.get(opts, :spool_remover, fn id ->
          ImportTransferSpool.remove_transfer(id, opts)
        end)

      _ = safely_remove_spool(remover, transfer_id)
      :ok
    else
      {:ok, %ImportTransfer{}} -> {:error, :conflict}
      {:error, :not_found} = error -> error
    end
  end

  @doc "Marks process-local apply claims left by a prior VM as retryable failures."
  def recover_stranded(opts \\ []) do
    now_value = Keyword.get(opts, :now, now())

    query =
      from(t in ImportTransfer,
        where:
          t.status == "applying" and not is_nil(t.apply_lease_expires_at) and
            t.apply_lease_expires_at < ^now_value,
        select: t.id
      )

    ids = Repo.all(query)

    if ids != [] do
      Repo.update_all(
        from(t in ImportTransfer,
          where:
            t.id in ^ids and t.status == "applying" and
              t.apply_lease_expires_at < ^now_value
        ),
        set: [
          status: "failed",
          error: "Import apply was interrupted by a server restart.",
          apply_claim_token: nil,
          apply_lease_expires_at: nil,
          updated_at: now()
        ]
      )
    end

    {:ok, ids}
  end

  def recover_stranded_applying(opts \\ []), do: recover_stranded(opts)

  @doc "Cancels stale open ledgers before deleting their spools and collects terminal/orphan dirs."
  def sweep(opts \\ []) do
    now_value = Keyword.get(opts, :now, now())
    max_age_ms = Keyword.get(opts, :max_age_ms, @default_max_age_ms)
    cutoff = DateTime.add(now_value, -max_age_ms, :millisecond)

    candidates =
      Repo.all(
        from(t in ImportTransfer,
          where: t.status in ^@cancel_statuses and t.updated_at < ^cutoff,
          select: t.id
        )
      )

    swept =
      Enum.count(candidates, fn id ->
        {count, _} =
          Repo.update_all(
            from(t in ImportTransfer,
              where:
                t.id == ^id and t.status in ^@cancel_statuses and
                  t.updated_at < ^cutoff
            ),
            set: [
              status: "cancelled",
              error: "Abandoned import transfer expired.",
              completed_at: now_value,
              updated_at: now_value
            ]
          )

        if count == 1, do: ImportTransferSpool.remove_transfer(id, opts)
        count == 1
      end)

    terminal_ids =
      Repo.all(
        from(t in ImportTransfer,
          where: t.status in ["completed", "cancelled"],
          select: t.id
        )
      )

    Enum.each(terminal_ids, &ImportTransferSpool.remove_transfer(&1, opts))
    orphaned = sweep_orphan_directories(MapSet.new(terminal_ids ++ candidates), cutoff, opts)

    {:ok, %{swept: swept, orphaned: orphaned}}
  end

  def sweep_abandoned(opts \\ []), do: sweep(opts)

  defp declare_locked(owner_user_id, declaration, opts) do
    Repo.transaction(fn ->
      Repo.query!(
        "SELECT pg_advisory_xact_lock(hashtextextended('company-import-declaration-capacity', 0))"
      )

      lock_key = "#{owner_user_id}|#{declaration.idempotency_key}"
      Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [lock_key])

      existing =
        Repo.one(
          from(t in ImportTransfer,
            where:
              t.owner_user_id == ^owner_user_id and
                t.idempotency_key == ^declaration.idempotency_key and
                t.status != "cancelled",
            order_by: [desc: t.inserted_at],
            limit: 1
          )
        )

      cond do
        existing && existing.manifest_sha256 != declaration.manifest_sha256 ->
          Repo.rollback(:manifest_conflict)

        existing ->
          {existing, true}

        true ->
          ensure_declaration_capacity!(owner_user_id, declaration.total_bytes, opts)

          transfer =
            %ImportTransfer{}
            |> ImportTransfer.create_changeset(%{
              owner_user_id: owner_user_id,
              target_company_id: declaration.target_company_id,
              status: "uploading",
              idempotency_key: declaration.idempotency_key,
              format: ImportTransfer.format(),
              import_options: declaration.import_options,
              total_bytes: declaration.total_bytes,
              part_size_bytes: declaration.part_size_bytes,
              part_count: length(declaration.parts),
              file_sha256: declaration.file_sha256,
              manifest_sha256: declaration.manifest_sha256,
              expires_at: DateTime.add(now(), @default_max_age_ms, :millisecond)
            })
            |> Repo.insert!()

          Enum.each(declaration.parts, fn attrs ->
            %ImportTransferPart{}
            |> ImportTransferPart.create_changeset(Map.put(attrs, :transfer_id, transfer.id))
            |> Repo.insert!()
          end)

          {transfer, false}
      end
    end)
    |> case do
      {:ok, {transfer, resumed}} -> {:ok, transfer, resumed}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error in Ecto.InvalidChangesetError -> {:error, error.changeset}
  end

  defp normalize_manifest(manifest, opts) when is_map(manifest) do
    with {:ok, idempotency_key} <- required_binary(manifest, :idempotency_key),
         true <- Regex.match?(@idempotency_re, idempotency_key),
         {:ok, total_bytes} <- required_integer(manifest, :total_bytes),
         true <- total_bytes > 0,
         true <- total_bytes <= max_total_bytes(opts),
         {:ok, part_size_bytes} <- required_integer(manifest, :part_size_bytes),
         true <- part_size_bytes > 0,
         true <- part_size_bytes <= max_part_bytes(opts),
         {:ok, file_sha256} <- required_binary(manifest, :file_sha256),
         true <- Regex.match?(@sha_re, file_sha256),
         {:ok, import_options} <- normalize_import_options(manifest),
         {:ok, raw_parts} <- required_list(manifest, :parts),
         true <- raw_parts != [] and length(raw_parts) <= @max_parts,
         {:ok, parts} <- normalize_parts(raw_parts, part_size_bytes),
         true <- Enum.sum(Enum.map(parts, & &1.byte_size)) == total_bytes do
      normalized = %{
        idempotency_key: idempotency_key,
        target_company_id: optional_field(manifest, :target_company_id),
        total_bytes: total_bytes,
        part_size_bytes: part_size_bytes,
        file_sha256: file_sha256,
        import_options: import_options,
        parts: parts
      }

      manifest_sha256 =
        normalized
        |> :erlang.term_to_binary([:deterministic])
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)

      {:ok, Map.put(normalized, :manifest_sha256, manifest_sha256)}
    else
      false -> {:error, manifest_error(manifest, opts)}
      {:error, _reason} -> {:error, :invalid_manifest}
    end
  end

  defp normalize_manifest(_manifest, _opts), do: {:error, :invalid_manifest}

  defp normalize_import_options(manifest) do
    raw_options =
      optional_field(manifest, :import_options) || optional_field(manifest, :options) || %{}

    if is_map(raw_options) do
      slug_strategy =
        optional_field(raw_options, :slug_strategy) || optional_field(manifest, :slug_strategy) ||
          "suffix"

      if slug_strategy in ["suffix", "fail", :suffix, :fail] do
        {:ok, %{"slug_strategy" => to_string(slug_strategy)}}
      else
        {:error, :invalid_import_options}
      end
    else
      {:error, :invalid_import_options}
    end
  end

  defp normalize_parts(raw_parts, part_size_bytes) do
    raw_parts
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {raw, expected_position}, {:ok, parts} ->
      with true <- is_map(raw),
           {:ok, position} <- required_integer(raw, :position, [:index]),
           true <- position == expected_position,
           {:ok, byte_size} <- required_integer(raw, :byte_size),
           true <- byte_size > 0 and byte_size <= part_size_bytes,
           {:ok, sha256} <- required_binary(raw, :sha256),
           true <- Regex.match?(@sha_re, sha256) do
        {:cont, {:ok, [%{position: position, byte_size: byte_size, sha256: sha256} | parts]}}
      else
        _ -> {:halt, {:error, :invalid_part}}
      end
    end)
    |> case do
      {:ok, parts} ->
        parts = Enum.reverse(parts)

        if Enum.all?(Enum.drop(parts, -1), &(&1.byte_size == part_size_bytes)) do
          {:ok, parts}
        else
          {:error, :invalid_part}
        end

      error ->
        error
    end
  end

  defp manifest_error(manifest, opts) do
    total = optional_field(manifest, :total_bytes)
    part_size = optional_field(manifest, :part_size_bytes)

    cond do
      is_integer(total) and total > max_total_bytes(opts) -> :too_large
      is_integer(part_size) and part_size > max_part_bytes(opts) -> :too_large
      true -> :invalid_manifest
    end
  end

  defp fetch_for_owner(transfer_id, owner_user_id)
       when is_binary(transfer_id) and is_binary(owner_user_id) do
    case Ecto.UUID.cast(transfer_id) do
      {:ok, id} ->
        case Repo.one(
               from(t in ImportTransfer,
                 where: t.id == ^id and t.owner_user_id == ^owner_user_id,
                 preload: [:parts]
               )
             ) do
          nil -> {:error, :not_found}
          transfer -> {:ok, transfer}
        end

      :error ->
        {:error, :not_found}
    end
  end

  defp fetch_for_owner(_transfer_id, _owner_user_id), do: {:error, :not_found}

  defp reconcile_missing_files(%ImportTransfer{status: "completed"} = transfer, _opts),
    do: {:ok, transfer}

  defp reconcile_missing_files(transfer, opts) do
    cleared? =
      transfer
      |> ordered_parts()
      |> Enum.filter(& &1.uploaded_at)
      |> Enum.reduce(false, fn part, changed? ->
        if ImportTransferSpool.verify_part(
             transfer.id,
             part.position,
             part.byte_size,
             part.sha256,
             opts
           ) do
          changed?
        else
          Repo.update_all(
            from(p in ImportTransferPart,
              where: p.id == ^part.id and not is_nil(p.uploaded_at)
            ),
            set: [uploaded_at: nil, updated_at: now()]
          )

          true
        end
      end)

    if cleared? do
      if transfer.status in ["ready", "failed"] do
        Repo.update_all(
          from(t in ImportTransfer,
            where: t.id == ^transfer.id and t.status in ["ready", "failed"]
          ),
          set: [status: "uploading", error: nil, updated_at: now()]
        )
      end

      fetch_for_owner(transfer.id, transfer.owner_user_id)
    else
      {:ok, transfer}
    end
  end

  defp declared_part(transfer, position) do
    case Enum.find(transfer.parts, &(&1.position == position)) do
      nil -> {:error, :invalid_part}
      part -> {:ok, part}
    end
  end

  defp uploadable(%ImportTransfer{status: status}) when status in @open_upload_statuses, do: :ok
  defp uploadable(_transfer), do: {:error, :conflict}

  defp completed_part_result(transfer, part, opts) do
    completed? =
      not is_nil(part.uploaded_at) and
        ImportTransferSpool.verify_part(
          transfer.id,
          part.position,
          part.byte_size,
          part.sha256,
          opts
        )

    {:continue, completed?}
  end

  defp put_claimed_part(transfer, part, owner_user_id, reader, initial_state, opts) do
    case claim_part_upload(
           transfer.id,
           part.id,
           owner_user_id,
           part.uploaded_at,
           opts
         ) do
      {:ok, {:completed, current_transfer}} ->
        {:ok,
         %{
           index: part.position,
           already_completed: true,
           transfer: current_transfer,
           reader_state: initial_state
         }}

      {:ok, {:claimed, claim_token}} ->
        installer = fn temp, target ->
          finalize_part_upload(
            transfer.id,
            part.id,
            owner_user_id,
            claim_token,
            temp,
            target
          )
        end

        ingest_opts = Keyword.put(opts, :verified_installer, installer)

        try do
          case ImportTransferSpool.ingest(
                 transfer.id,
                 part.position,
                 part.byte_size,
                 part.sha256,
                 reader,
                 initial_state,
                 ingest_opts
               ) do
            {:ok, final_reader_state, current_transfer} ->
              {:ok,
               %{
                 index: part.position,
                 already_completed: false,
                 transfer: current_transfer,
                 reader_state: final_reader_state
               }}

            {:error, reason} ->
              {:error, reason}
          end
        after
          release_part_upload(part.id, claim_token)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp claim_part_upload(
         transfer_id,
         part_id,
         owner_user_id,
         observed_uploaded_at,
         opts
       ) do
    Repo.transaction(fn ->
      transfer = locked_transfer(transfer_id, owner_user_id)

      cond do
        is_nil(transfer) ->
          Repo.rollback(:not_found)

        transfer.status not in @open_upload_statuses ->
          Repo.rollback(:conflict)

        true ->
          locked_part =
            Repo.one!(
              from(p in ImportTransferPart,
                where: p.id == ^part_id and p.transfer_id == ^transfer.id,
                lock: "FOR UPDATE"
              )
            )

          now_value = Keyword.get(opts, :now, now())

          cond do
            not is_nil(locked_part.uploaded_at) and
                locked_part.uploaded_at != observed_uploaded_at ->
              {:completed, transfer}

            live_upload_claim?(locked_part, now_value) ->
              Repo.rollback(:upload_in_progress)

            true ->
              token = random_token()

              locked_part
              |> Ecto.Changeset.change(
                uploaded_at: nil,
                upload_claim_token: token,
                upload_lease_expires_at:
                  DateTime.add(now_value, upload_lease_ms(opts), :millisecond),
                updated_at: now_value
              )
              |> Repo.update!()

              transfer
              |> Ecto.Changeset.change(status: "uploading", error: nil, updated_at: now_value)
              |> Repo.update!()

              {:claimed, token}
          end
      end
    end)
    |> transaction_result()
  end

  defp finalize_part_upload(
         transfer_id,
         part_id,
         owner_user_id,
         claim_token,
         temp,
         target
       ) do
    Repo.transaction(fn ->
      transfer = locked_transfer(transfer_id, owner_user_id)

      cond do
        is_nil(transfer) ->
          Repo.rollback(:not_found)

        transfer.status not in @open_upload_statuses ->
          Repo.rollback(:conflict)

        true ->
          part =
            Repo.one!(
              from(p in ImportTransferPart,
                where: p.id == ^part_id and p.transfer_id == ^transfer.id,
                lock: "FOR UPDATE"
              )
            )

          if not secure_token?(part.upload_claim_token, claim_token) do
            Repo.rollback(:conflict)
          end

          case File.rename(temp, target) do
            :ok -> :ok
            {:error, reason} -> Repo.rollback({:spool_write_failed, reason})
          end

          _ = File.chmod(target, 0o600)
          now_value = now()

          part
          |> Ecto.Changeset.change(
            uploaded_at: now_value,
            upload_claim_token: nil,
            upload_lease_expires_at: nil,
            updated_at: now_value
          )
          |> Repo.update!()

          missing =
            Repo.aggregate(
              from(p in ImportTransferPart,
                where: p.transfer_id == ^transfer.id and is_nil(p.uploaded_at)
              ),
              :count
            )

          transfer
          |> Ecto.Changeset.change(
            status: if(missing == 0, do: "ready", else: "uploading"),
            error: nil,
            started_at: transfer.started_at || now_value,
            updated_at: now_value
          )
          |> Repo.update!()
      end
    end)
    |> transaction_result()
  end

  defp release_part_upload(part_id, claim_token) do
    Repo.update_all(
      from(p in ImportTransferPart,
        where:
          p.id == ^part_id and p.upload_claim_token == ^claim_token and
            is_nil(p.uploaded_at)
      ),
      set: [upload_claim_token: nil, upload_lease_expires_at: nil, updated_at: now()]
    )

    :ok
  end

  defp live_upload_claim?(part, now_value) do
    not is_nil(part.upload_claim_token) and not is_nil(part.upload_lease_expires_at) and
      DateTime.compare(part.upload_lease_expires_at, now_value) == :gt
  end

  defp upload_lease_ms(opts) do
    case Keyword.get(opts, :upload_lease_ms, @default_upload_lease_ms) do
      value when is_integer(value) and value > 0 -> value
      _invalid -> @default_upload_lease_ms
    end
  end

  defp decodable_transfer(%ImportTransfer{status: status, id: id})
       when status in ["ready", "failed", "applying"] do
    if missing_part_count(id) == 0, do: :ok, else: {:error, :missing_parts}
  end

  defp decodable_transfer(_transfer), do: {:error, :not_ready}

  defp matching_file_hash(actual, expected) do
    if Plug.Crypto.secure_compare(actual, expected),
      do: :ok,
      else: {:error, :file_sha256_mismatch}
  end

  defp authorize_target(_owner_user_id, nil), do: :ok

  defp authorize_target(owner_user_id, company_id) when is_binary(company_id) do
    if target_authorized?(owner_user_id, company_id), do: :ok, else: {:error, :not_found}
  end

  defp authorize_target(_owner_user_id, _company_id), do: {:error, :invalid_manifest}

  defp target_authorized?(_owner_user_id, nil), do: true

  defp target_authorized?(owner_user_id, company_id) do
    Cympho.CompanyRBAC.manager?(owner_user_id, company_id)
  end

  defp missing_part_count(transfer_id) do
    Repo.aggregate(
      from(p in ImportTransferPart,
        where: p.transfer_id == ^transfer_id and is_nil(p.uploaded_at)
      ),
      :count
    )
  end

  defp ensure_declaration_capacity!(owner_user_id, incoming_bytes, opts) do
    limits = admission_limits(opts)

    actor = declaration_usage(owner_user_id)
    global = declaration_usage(nil)

    actor_bytes = integer_value(actor.bytes)
    global_bytes = integer_value(global.bytes)

    if actor.count >= limits.actor_open or actor_bytes + incoming_bytes > limits.actor_bytes or
         global.count >= limits.global_open or
         global_bytes + incoming_bytes > limits.global_bytes do
      Repo.rollback(:capacity_exceeded)
    end
  end

  defp declaration_usage(owner_user_id) do
    query =
      from(t in ImportTransfer,
        where: t.status in ["uploading", "ready", "applying", "failed"]
      )

    query =
      if owner_user_id,
        do: from(t in query, where: t.owner_user_id == ^owner_user_id),
        else: query

    Repo.one(
      from(t in query,
        select: %{
          count: count(t.id),
          bytes: coalesce(sum(t.total_bytes), 0)
        }
      )
    )
  end

  defp limit(opts, option, application_key, default) do
    case Keyword.get(opts, option, Application.get_env(:cympho, application_key, default)) do
      value when is_integer(value) and value > 0 -> value
      _invalid -> default
    end
  end

  defp positive_limit(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_limit(_value, default), do: default

  defp map_integer(map, key) do
    case Map.get(map, key, Map.get(map, Atom.to_string(key))) do
      value when is_integer(value) and value >= 0 -> value
      _invalid -> nil
    end
  end

  defp normalize_secret_receipt(entries) when is_list(entries) do
    entries
    |> Enum.take(@default_max_secret_receipt_entries)
    |> Enum.flat_map(fn
      entry when is_map(entry) ->
        [sanitize_secret_receipt_entry(entry)]

      _invalid ->
        []
    end)
    |> take_receipt_bytes()
  end

  defp normalize_secret_receipt(_entries), do: []

  defp sanitize_secret_receipt_entry(entry) do
    receipt =
      Enum.reduce(@secret_receipt_binary_limits, %{}, fn {key, max_length}, metadata ->
        case receipt_value(entry, key) do
          value when is_binary(value) ->
            if String.valid?(value),
              do: Map.put(metadata, key, String.slice(value, 0, max_length)),
              else: metadata

          nil ->
            Map.put(metadata, key, nil)

          _invalid ->
            metadata
        end
      end)

    case receipt_value(entry, :version) do
      version when is_integer(version) and version > 0 -> Map.put(receipt, :version, version)
      _invalid -> receipt
    end
  end

  defp receipt_value(entry, key) do
    Map.get(entry, key, Map.get(entry, Atom.to_string(key)))
  end

  defp take_receipt_bytes(entries) do
    entries
    |> Enum.reduce_while({[], 2}, fn entry, {kept, bytes} ->
      entry_bytes = encoded_size(entry) + if(kept == [], do: 0, else: 1)

      if bytes + entry_bytes <= @default_max_secret_receipt_bytes,
        do: {:cont, {[entry | kept], bytes + entry_bytes}},
        else: {:halt, {kept, bytes}}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp encoded_size(term) do
    case Jason.encode(term) do
      {:ok, encoded} -> byte_size(encoded)
      {:error, _reason} -> @default_max_secret_receipt_bytes + 1
    end
  end

  defp apply_lease_ms(opts) do
    case Keyword.get(opts, :apply_lease_ms, @default_apply_lease_ms) do
      value when is_integer(value) and value > 0 -> value
      _invalid -> @default_apply_lease_ms
    end
  end

  defp random_token do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  defp secure_token?(expected, actual)
       when is_binary(expected) and is_binary(actual) and byte_size(expected) == byte_size(actual),
       do: Plug.Crypto.secure_compare(expected, actual)

  defp secure_token?(_expected, _actual), do: false

  defp integer_value(%Decimal{} = value), do: Decimal.to_integer(value)
  defp integer_value(value) when is_integer(value), do: value

  defp transition(transfer_id, owner_user_id, allowed_statuses, fun) do
    Repo.transaction(fn ->
      case locked_transfer(transfer_id, owner_user_id) do
        nil ->
          Repo.rollback(:not_found)

        %{status: status} = transfer ->
          if status in allowed_statuses, do: fun.(transfer), else: Repo.rollback(:conflict)
      end
    end)
    |> transaction_result()
  end

  defp locked_transfer(transfer_id, owner_user_id) do
    with {:ok, id} <- Ecto.UUID.cast(transfer_id) do
      Repo.one(
        from(t in ImportTransfer,
          where: t.id == ^id and t.owner_user_id == ^owner_user_id,
          lock: "FOR UPDATE"
        )
      )
    else
      :error -> nil
    end
  end

  defp transaction_result({:ok, value}), do: {:ok, value}
  defp transaction_result({:error, reason}), do: {:error, reason}

  defp ordered_parts(transfer), do: Enum.sort_by(transfer.parts, & &1.position)

  defp part_descriptors(transfer) do
    Enum.map(
      ordered_parts(transfer),
      &%{position: &1.position, byte_size: &1.byte_size, sha256: &1.sha256}
    )
  end

  defp sweep_orphan_directories(known_ids, cutoff, opts) do
    case ImportTransferSpool.list_transfer_directories(opts) do
      {:ok, ids} ->
        Enum.count(ids, fn id ->
          exists? = Repo.exists?(from(t in ImportTransfer, where: t.id == ^id))

          if not exists? and not MapSet.member?(known_ids, id) do
            case ImportTransferSpool.directory_mtime(id, opts) do
              {:ok, mtime} when mtime < cutoff ->
                ImportTransferSpool.remove_transfer(id, opts) == :ok

              _ ->
                false
            end
          else
            false
          end
        end)

      _ ->
        0
    end
  end

  defp required_binary(map, key, aliases \\ []) do
    case optional_field(map, key, aliases) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, key}
    end
  end

  defp required_integer(map, key, aliases \\ []) do
    case optional_field(map, key, aliases) do
      value when is_integer(value) -> {:ok, value}
      _ -> {:error, key}
    end
  end

  defp required_list(map, key) do
    case optional_field(map, key) do
      value when is_list(value) -> {:ok, value}
      _ -> {:error, key}
    end
  end

  defp optional_field(map, key, aliases \\ []) do
    Enum.find_value([key, Atom.to_string(key) | aliases], fn candidate ->
      string_candidate = if is_atom(candidate), do: Atom.to_string(candidate), else: candidate

      cond do
        Map.has_key?(map, candidate) -> {:found, Map.get(map, candidate)}
        Map.has_key?(map, string_candidate) -> {:found, Map.get(map, string_candidate)}
        true -> nil
      end
    end)
    |> case do
      {:found, value} -> value
      nil -> nil
    end
  end

  defp safe_error(:invalid_json), do: "Import package could not be decoded."
  defp safe_error(:integrity_error), do: "Import package integrity verification failed."
  defp safe_error(:file_sha256_mismatch), do: "Import package integrity verification failed."
  defp safe_error(:cancelled), do: "Import transfer was cancelled."
  defp safe_error(_reason), do: "Company import failed."

  defp safely_remove_spool(remover, transfer_id) when is_function(remover, 1) do
    remover.(transfer_id)
  rescue
    _exception -> :error
  catch
    _kind, _reason -> :error
  end

  defp safely_remove_spool(_remover, _transfer_id), do: :error

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
