defmodule Cympho.Companies.ImportTransfersTest do
  use Cympho.DataCase, async: false

  alias Cympho.Authentication
  alias Cympho.Companies
  alias Cympho.Companies.Company
  alias Cympho.Companies.ImportTransfer
  alias Cympho.Companies.ImportTransferPart
  alias Cympho.Companies.ImportTransferSpool
  alias Cympho.Companies.ImportTransfers

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "cympho-import-transfer-test-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(root) end)

    {:ok, user} =
      Authentication.register_user(%{
        email: "transfer-#{System.unique_integer([:positive])}@example.test",
        name: "Transfer Owner",
        password: "password123"
      })

    %{owner: user, spool_root: root}
  end

  test "strict declaration validates caps, order, sizes, and hashes", %{owner: owner} do
    body = ~s({"version":1})
    manifest = manifest(body, 4)

    assert {:error, :too_large} =
             ImportTransfers.declare(owner.id, manifest, max_total_bytes: byte_size(body) - 1)

    assert {:error, :too_large} =
             ImportTransfers.declare(owner.id, manifest, max_part_bytes: 3)

    assert {:error, :invalid_manifest} =
             ImportTransfers.declare(owner.id, %{manifest | file_sha256: "bad"})

    [first, second | rest] = manifest.parts

    assert {:error, :invalid_manifest} =
             ImportTransfers.declare(owner.id, %{
               manifest
               | parts: [second, first | rest]
             })

    assert {:error, :invalid_manifest} =
             ImportTransfers.declare(owner.id, %{
               manifest
               | total_bytes: manifest.total_bytes + 1
             })
  end

  test "declaration and apply admission are bounded by database-backed capacity", %{
    owner: owner,
    spool_root: root
  } do
    first = manifest(~s({"version":1}), 4)

    assert {:ok, first_result} =
             ImportTransfers.declare(owner.id, first,
               spool_root: root,
               max_actor_open: 1
             )

    second = Map.put(first, :idempotency_key, idempotency_key())

    assert {:error, :capacity_exceeded} =
             ImportTransfers.declare(owner.id, second,
               spool_root: root,
               max_actor_open: 1
             )

    assert {:ok, _} = ImportTransfers.cancel(first_result.transfer.id, owner.id, spool_root: root)

    {:ok, applying_one} = declare_and_upload(owner.id, ~s({"version":1}), 4, root)
    {:ok, applying_two} = declare_and_upload(owner.id, ~s({"version":2}), 4, root)
    assert {:ok, first_claim} = ImportTransfers.claim_apply(applying_one.transfer.id, owner.id)

    assert {:error, :capacity_exceeded} =
             ImportTransfers.claim_apply(applying_two.transfer.id, owner.id, max_applying: 1)

    assert {:ok, _} =
             ImportTransfers.fail(
               applying_one.transfer.id,
               owner.id,
               first_claim.apply_claim_token,
               :test
             )
  end

  test "same actor and immutable manifest resume; foreign actors cannot discover it", %{
    owner: owner,
    spool_root: root
  } do
    body = ~s({"version":1})
    declaration = manifest(body, 5)

    assert {:ok, first} = ImportTransfers.declare(owner.id, declaration, spool_root: root)
    refute first.resumed

    assert {:ok, resumed} = ImportTransfers.declare(owner.id, declaration, spool_root: root)
    assert resumed.resumed
    assert resumed.transfer.id == first.transfer.id

    {:ok, other} =
      Authentication.register_user(%{
        email: "other-#{System.unique_integer([:positive])}@example.test",
        name: "Other",
        password: "password123"
      })

    assert {:error, :not_found} = ImportTransfers.status(first.transfer.id, other.id)

    changed = %{declaration | file_sha256: sha256("different")}
    assert {:error, :manifest_conflict} = ImportTransfers.declare(owner.id, changed)

    changed_options =
      Map.put(declaration, :import_options, %{"slug_strategy" => "fail"})

    assert {:error, :manifest_conflict} =
             ImportTransfers.declare(owner.id, changed_options)
  end

  test "parts stream in bounded chunks, reject corrupt input, and retry idempotently", %{
    owner: owner,
    spool_root: root
  } do
    body = ~s({"company":{"name":"Boundary"},"version":1})
    declaration = manifest(body, 9)
    {:ok, result} = ImportTransfers.declare(owner.id, declaration, spool_root: root)
    transfer = result.transfer
    chunks = chunks(body, 9)

    assert {:error, {:reader_error, :reader_failed}} =
             ImportTransfers.put_part_from_reader(
               transfer.id,
               owner.id,
               0,
               fn _state -> raise "reader failed" end,
               reader_state: :start,
               spool_root: root
             )

    failed_part =
      Repo.one!(
        from p in ImportTransferPart, where: p.transfer_id == ^transfer.id and p.position == 0
      )

    assert is_nil(failed_part.upload_claim_token)
    assert is_nil(failed_part.upload_lease_expires_at)

    assert {:error, :part_sha256_mismatch} =
             upload(transfer.id, owner.id, 0, [String.duplicate("x", 9)], root)

    assert {:ok, progress} = ImportTransfers.status(transfer.id, owner.id, spool_root: root)
    assert progress.uploaded_parts == 0

    Enum.with_index(chunks)
    |> Enum.each(fn {part, position} ->
      tiny_chunks = for <<byte <- part>>, do: <<byte>>

      assert {:ok, %{already_completed: false, reader_state: []}} =
               upload(transfer.id, owner.id, position, tiny_chunks, root)
    end)

    assert {:ok, progress} = ImportTransfers.status(transfer.id, owner.id, spool_root: root)
    assert progress.missing_parts == []
    assert progress.transfer.status == "ready"

    assert {:ok, %{already_completed: true}} =
             upload(transfer.id, owner.id, 0, [hd(chunks)], root)
  end

  test "a live database upload claim rejects a duplicate before reading its body", %{
    owner: owner,
    spool_root: root
  } do
    body = ~s({"version":1})
    {:ok, result} = ImportTransfers.declare(owner.id, manifest(body, byte_size(body)))
    parent = self()

    first =
      Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())
        send(parent, {:uploader_ready, self()})

        receive do
          :upload ->
            reader = fn
              :start ->
                send(parent, :first_reader_started)

                receive do
                  :release_first_reader -> {:ok, body, :done}
                end

              :done ->
                :eof
            end

            ImportTransfers.put_part_from_reader(
              result.transfer.id,
              owner.id,
              0,
              reader,
              reader_state: :start,
              spool_root: root
            )
        end
      end)

    assert_receive {:uploader_ready, uploader_pid}
    send(uploader_pid, :upload)
    assert_receive :first_reader_started

    duplicate_reader = fn state ->
      send(parent, :duplicate_reader_was_called)
      {:ok, body, state}
    end

    assert {:error, :upload_in_progress} =
             ImportTransfers.put_part_from_reader(
               result.transfer.id,
               owner.id,
               0,
               duplicate_reader,
               reader_state: :unused,
               spool_root: root
             )

    refute_receive :duplicate_reader_was_called
    send(first.pid, :release_first_reader)
    assert {:ok, %{already_completed: false}} = Task.await(first)
  end

  test "an expired upload claim is reclaimed without stale cleanup deleting the winner", %{
    owner: owner,
    spool_root: root
  } do
    body = ~s({"version":1})
    {:ok, result} = ImportTransfers.declare(owner.id, manifest(body, byte_size(body)))
    parent = self()
    stale_now = DateTime.add(DateTime.utc_now(), -11, :minute)

    stale =
      Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())
        send(parent, {:stale_uploader_ready, self()})

        receive do
          :upload ->
            reader = fn
              :start ->
                send(parent, :stale_reader_started)

                receive do
                  :release_stale_reader -> {:ok, body, :done}
                end

              :done ->
                :eof
            end

            ImportTransfers.put_part_from_reader(
              result.transfer.id,
              owner.id,
              0,
              reader,
              reader_state: :start,
              spool_root: root,
              now: stale_now
            )
        end
      end)

    assert_receive {:stale_uploader_ready, stale_pid}
    send(stale_pid, :upload)
    assert_receive :stale_reader_started

    assert {:ok, %{already_completed: false}} =
             upload(result.transfer.id, owner.id, 0, [body], root)

    send(stale.pid, :release_stale_reader)
    assert {:error, :conflict} = Task.await(stale)

    assert {:ok, progress} =
             ImportTransfers.status(result.transfer.id, owner.id, spool_root: root)

    assert progress.uploaded_positions == [0]
    assert progress.transfer.status == "ready"

    part = Repo.one!(from p in ImportTransferPart, where: p.transfer_id == ^result.transfer.id)
    assert is_nil(part.upload_claim_token)
    assert is_nil(part.upload_lease_expires_at)

    {:ok, target} = ImportTransferSpool.part_path(result.transfer.id, 0, spool_root: root)
    assert File.read!(target) == body
    assert {:ok, ["part-0"]} = target |> Path.dirname() |> File.ls()
  end

  test "missing or same-size corrupted spool files are reconciled and re-uploaded", %{
    owner: owner,
    spool_root: root
  } do
    body = ~s({"version":1,"items":[1,2,3]})
    declaration = manifest(body, 8)
    {:ok, result} = ImportTransfers.declare(owner.id, declaration, spool_root: root)

    declaration.parts
    |> Enum.zip(chunks(body, 8))
    |> Enum.each(fn {part, bytes} ->
      assert {:ok, _} = upload(result.transfer.id, owner.id, part.position, [bytes], root)
    end)

    {:ok, first_path} = ImportTransferSpool.part_path(result.transfer.id, 0, spool_root: root)
    original = File.read!(first_path)
    File.write!(first_path, :binary.copy(<<0>>, byte_size(original)))

    assert {:ok, progress} =
             ImportTransfers.status(result.transfer.id, owner.id, spool_root: root)

    assert 0 in progress.missing_parts
    assert progress.transfer.status == "uploading"
    assert {:ok, _} = upload(result.transfer.id, owner.id, 0, [original], root)

    File.rm!(first_path)

    assert {:ok, progress} =
             ImportTransfers.status(result.transfer.id, owner.id, spool_root: root)

    assert 0 in progress.missing_parts
  end

  test "whole hash and OTP JSON decode cross every part boundary without raw concatenation", %{
    owner: owner,
    spool_root: root
  } do
    body =
      Jason.encode!(%{
        "version" => 1,
        "company" => %{"name" => "Split ☺", "nullable" => nil},
        "items" => Enum.to_list(1..100)
      })

    declaration = manifest(body, 3)
    {:ok, result} = ImportTransfers.declare(owner.id, declaration, spool_root: root)

    Enum.with_index(chunks(body, 3))
    |> Enum.each(fn {bytes, position} ->
      assert {:ok, _} = upload(result.transfer.id, owner.id, position, [bytes], root)
    end)

    assert {:ok, decoded} =
             ImportTransfers.decode(result.transfer.id, owner.id, spool_root: root)

    assert decoded["company"]["name"] == "Split ☺"
    assert decoded["company"]["nullable"] == nil
    assert decoded["items"] == Enum.to_list(1..100)

    {:ok, last_path} =
      ImportTransferSpool.part_path(
        result.transfer.id,
        length(declaration.parts) - 1,
        spool_root: root
      )

    last = File.read!(last_path)
    File.write!(last_path, :binary.copy(<<1>>, byte_size(last)))

    assert {:error, :integrity_error} =
             ImportTransfers.decode(result.transfer.id, owner.id, spool_root: root)
  end

  test "claim, fail, retry, complete and cancel follow guarded states", %{
    owner: owner,
    spool_root: root
  } do
    body = ~s({"version":1})
    {:ok, result} = declare_and_upload(owner.id, body, 4, root)

    assert {:ok, applying} = ImportTransfers.claim_apply(result.transfer.id, owner.id)
    assert applying.status == "applying"
    token = applying.apply_claim_token
    assert {:error, :not_ready} = ImportTransfers.claim_apply(result.transfer.id, owner.id)
    assert {:error, :conflict} = ImportTransfers.cancel(result.transfer.id, owner.id)

    assert {:error, :conflict} =
             ImportTransfers.fail(result.transfer.id, owner.id, "stale-token", :down)

    assert {:ok, failed} =
             ImportTransfers.fail(result.transfer.id, owner.id, token, {:adapter, :down})

    assert failed.status == "failed"
    assert failed.error == "Company import failed."

    assert {:ok, retrying} = ImportTransfers.claim_apply(result.transfer.id, owner.id)

    assert {:ok, completed} =
             ImportTransfers.complete(
               result.transfer.id,
               owner.id,
               retrying.apply_claim_token
             )

    assert completed.status == "completed"

    assert {:error, :conflict} =
             ImportTransfers.complete(result.transfer.id, owner.id, retrying.apply_claim_token)

    fresh = manifest(body, 4) |> Map.put(:idempotency_key, idempotency_key())
    {:ok, fresh} = ImportTransfers.declare(owner.id, fresh, spool_root: root)

    assert {:ok, cancelled} =
             ImportTransfers.cancel(fresh.transfer.id, owner.id, spool_root: root)

    assert cancelled.status == "cancelled"
    assert {:error, :conflict} = ImportTransfers.cancel(fresh.transfer.id, owner.id)
  end

  test "transactional completion rolls back with its caller and startup recovery is retryable", %{
    owner: owner,
    spool_root: root
  } do
    {:ok, result} = declare_and_upload(owner.id, ~s({"version":1}), 4, root)
    {:ok, applying} = ImportTransfers.claim_apply(result.transfer.id, owner.id)

    assert {:error, :forced_rollback} =
             Repo.transaction(fn ->
               assert :ok =
                        ImportTransfers.complete_in_transaction(
                          Repo,
                          result.transfer.id,
                          owner.id,
                          applying.apply_claim_token
                        )

               Repo.rollback(:forced_rollback)
             end)

    assert Repo.get!(ImportTransfer, result.transfer.id).status == "applying"
    assert {:ok, []} = ImportTransfers.recover_stranded()

    assert {:ok, [id]} =
             ImportTransfers.recover_stranded(now: DateTime.add(DateTime.utc_now(), 31, :minute))

    assert id == result.transfer.id
    assert Repo.get!(ImportTransfer, id).status == "failed"
  end

  test "transactional completion persists only the actor-scoped secret restore receipt", %{
    owner: owner,
    spool_root: root
  } do
    {:ok, result} = declare_and_upload(owner.id, ~s({"version":1}), 4, root)
    {:ok, applying} = ImportTransfers.claim_apply(result.transfer.id, owner.id)

    receipt_entry =
      %{
        key: "COMPANY_TOKEN",
        scope: "company",
        scope_id: nil,
        original_scope_id: nil,
        description: "Restore after import",
        version: 2,
        restore_status: "requires_value",
        value: %{"nested" => "must-not-persist"}
      }

    receipt = [receipt_entry | List.duplicate(receipt_entry, 5_000)]

    assert {:ok, :ok} =
             Repo.transaction(fn ->
               ImportTransfers.complete_in_transaction(
                 Repo,
                 result.transfer.id,
                 owner.id,
                 applying.apply_claim_token,
                 nil,
                 receipt
               )
             end)

    assert {:ok, status} = ImportTransfers.status(result.transfer.id, owner.id)
    assert [stored | _] = status.transfer.secrets_to_restore
    assert length(status.transfer.secrets_to_restore) <= 5_000
    assert byte_size(Jason.encode!(status.transfer.secrets_to_restore)) <= 1_000_000
    assert stored["key"] == "COMPANY_TOKEN" or stored[:key] == "COMPANY_TOKEN"
    refute Map.has_key?(stored, "value")
    refute Map.has_key?(stored, :value)

    {:ok, other} =
      Authentication.register_user(%{
        email: "receipt-other-#{System.unique_integer([:positive])}@example.test",
        name: "Other",
        password: "password123"
      })

    assert {:error, :not_found} = ImportTransfers.status(result.transfer.id, other.id)
  end

  test "completed-spool cleanup is actor-scoped, immediate, and fail-open", %{
    owner: owner,
    spool_root: root
  } do
    {:ok, result} = declare_and_upload(owner.id, ~s({"version":1}), 4, root)
    {:ok, applying} = ImportTransfers.claim_apply(result.transfer.id, owner.id)

    assert {:ok, completed} =
             ImportTransfers.complete(
               result.transfer.id,
               owner.id,
               applying.apply_claim_token
             )

    {:ok, part_path} =
      ImportTransferSpool.part_path(completed.id, 0, spool_root: root)

    assert File.exists?(part_path)

    {:ok, other} =
      Authentication.register_user(%{
        email: "cleanup-other-#{System.unique_integer([:positive])}@example.test",
        name: "Other cleanup actor",
        password: "password123"
      })

    assert {:error, :not_found} =
             ImportTransfers.cleanup_completed_spool(completed.id, other.id, spool_root: root)

    assert :ok =
             ImportTransfers.cleanup_completed_spool(completed.id, owner.id,
               spool_root: root,
               spool_remover: fn _id -> raise "simulated cleanup failure" end
             )

    assert Repo.get!(ImportTransfer, completed.id).status == "completed"
    assert File.exists?(part_path)

    assert :ok =
             ImportTransfers.cleanup_completed_spool(completed.id, owner.id, spool_root: root)

    refute File.exists?(part_path)
    assert Repo.get!(ImportTransfer, completed.id).status == "completed"
  end

  test "apply plan bounds reject record and write amplification" do
    preview = %{
      inventory: %{package_records: 101, planned_writes: 80, secret_restore_requirements: 0},
      secret_restore_requirements: []
    }

    assert {:error, :package_capacity_exceeded} =
             ImportTransfers.validate_apply_capacity(preview,
               max_package_records: 100,
               max_planned_writes: 100
             )

    assert {:error, :package_capacity_exceeded} =
             ImportTransfers.validate_apply_capacity(preview,
               max_package_records: 200,
               max_planned_writes: 79
             )

    assert :ok =
             ImportTransfers.validate_apply_capacity(preview,
               max_package_records: 101,
               max_planned_writes: 80
             )
  end

  test "direct company imports enforce write bounds before opening a transaction" do
    {:ok, source} =
      Companies.create_company(%{
        name: "Bounded direct import",
        slug: "bounded-direct-#{System.unique_integer([:positive])}"
      })

    {:ok, _project} =
      Cympho.Projects.create_project(%{
        company_id: source.id,
        name: "Amplified write",
        prefix: "BDI"
      })

    package = source.id |> Companies.export_company() |> Jason.encode!() |> Jason.decode!()
    company_count = Repo.aggregate(Company, :count)

    assert {:error, :package_capacity_exceeded} =
             Companies.import_company(package, max_package_records: 1)

    assert Repo.aggregate(Company, :count) == company_count
  end

  test "an expired apply lease is reclaimed without an ABA completion window", %{
    owner: owner,
    spool_root: root
  } do
    {:ok, result} = declare_and_upload(owner.id, ~s({"version":1}), 4, root)

    assert {:ok, old_claim} = ImportTransfers.claim_apply(result.transfer.id, owner.id)

    assert {:ok, new_claim} =
             ImportTransfers.claim_apply(result.transfer.id, owner.id,
               now: DateTime.add(DateTime.utc_now(), 31, :minute)
             )

    refute new_claim.apply_claim_token == old_claim.apply_claim_token

    assert {:error, :conflict} =
             ImportTransfers.complete(
               result.transfer.id,
               owner.id,
               old_claim.apply_claim_token
             )

    assert {:ok, completed} =
             ImportTransfers.complete(
               result.transfer.id,
               owner.id,
               new_claim.apply_claim_token
             )

    assert completed.status == "completed"
  end

  test "sweep claims stale ledgers before deletion and ignores fresh activity", %{
    owner: owner,
    spool_root: root
  } do
    body = ~s({"version":1})
    declaration = manifest(body, 4)
    {:ok, old} = ImportTransfers.declare(owner.id, declaration, spool_root: root)
    [first | _] = chunks(body, 4)
    {:ok, _} = upload(old.transfer.id, owner.id, 0, [first], root)

    fresh_manifest = Map.put(declaration, :idempotency_key, idempotency_key())
    {:ok, fresh} = ImportTransfers.declare(owner.id, fresh_manifest, spool_root: root)

    stale = DateTime.add(DateTime.utc_now(), -25, :hour)

    Repo.update_all(
      from(t in ImportTransfer, where: t.id == ^old.transfer.id),
      set: [updated_at: stale]
    )

    assert {:ok, %{swept: 1}} =
             ImportTransfers.sweep(spool_root: root, max_age_ms: 24 * 60 * 60 * 1000)

    assert Repo.get!(ImportTransfer, old.transfer.id).status == "cancelled"
    assert Repo.get!(ImportTransfer, fresh.transfer.id).status == "uploading"
  end

  test "spool refuses symlink roots and traversal ids", %{spool_root: root} do
    real = root <> "-real"
    File.mkdir_p!(real)
    File.ln_s!(real, root)

    assert {:error, :unsafe_spool_root} = ImportTransferSpool.prepare_root(spool_root: root)

    assert {:error, :invalid_transfer_id} =
             ImportTransferSpool.part_path("../escape", 0, spool_root: real)
  end

  test "spool refuses a symlinked UUID transfer directory without following it", %{
    spool_root: root
  } do
    {:ok, prepared_root} = ImportTransferSpool.prepare_root(spool_root: root)
    external = root <> "-external"
    File.mkdir_p!(external)
    File.chmod!(external, 0o755)
    id = Ecto.UUID.generate()
    File.ln_s!(external, Path.join(prepared_root, id))

    assert {:error, :unsafe_transfer_directory} =
             ImportTransferSpool.part_path(id, 0, spool_root: root)

    assert {:ok, %File.Stat{mode: mode}} = File.stat(external)
    assert Bitwise.band(mode, 0o777) == 0o755
  end

  defp declare_and_upload(owner_id, body, part_size, root) do
    declaration = manifest(body, part_size)
    {:ok, result} = ImportTransfers.declare(owner_id, declaration, spool_root: root)

    Enum.with_index(chunks(body, part_size))
    |> Enum.each(fn {bytes, position} ->
      assert {:ok, _} = upload(result.transfer.id, owner_id, position, [bytes], root)
    end)

    {:ok, result}
  end

  defp upload(transfer_id, owner_id, position, chunks, root) do
    reader = fn
      [chunk | rest] -> {:ok, chunk, rest}
      [] -> :eof
    end

    ImportTransfers.put_part_from_reader(
      transfer_id,
      owner_id,
      position,
      reader,
      reader_state: chunks,
      spool_root: root
    )
  end

  defp manifest(body, part_size) do
    parts =
      body
      |> chunks(part_size)
      |> Enum.with_index()
      |> Enum.map(fn {bytes, position} ->
        %{position: position, byte_size: byte_size(bytes), sha256: sha256(bytes)}
      end)

    %{
      idempotency_key: idempotency_key(),
      total_bytes: byte_size(body),
      part_size_bytes: part_size,
      file_sha256: sha256(body),
      parts: parts
    }
  end

  defp chunks(binary, size) do
    split_chunks(binary, size, [])
  end

  defp split_chunks(<<>>, _size, acc), do: Enum.reverse(acc)

  defp split_chunks(binary, size, acc) do
    take = min(size, byte_size(binary))
    <<chunk::binary-size(take), rest::binary>> = binary
    split_chunks(rest, size, [chunk | acc])
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp idempotency_key do
    "transfer_" <> (:crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false))
  end
end
