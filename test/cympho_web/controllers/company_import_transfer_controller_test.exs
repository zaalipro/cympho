defmodule CymphoWeb.CompanyImportTransferControllerTest do
  use CymphoWeb.ConnCase, async: false

  alias Cympho.Companies
  alias Cympho.Companies.ImportDecodeAdmission
  alias Cympho.Companies.ImportTransfer
  alias Cympho.Companies.ImportTransferPart
  alias Cympho.Repo

  setup %{conn: conn} do
    spool_root =
      Path.join(
        System.tmp_dir!(),
        "cympho-import-transfer-controller-#{System.unique_integer([:positive])}"
      )

    previous_root = Application.get_env(:cympho, :company_import_transfer_spool_root)
    Application.put_env(:cympho, :company_import_transfer_spool_root, spool_root)

    on_exit(fn ->
      File.rm_rf!(spool_root)

      if previous_root do
        Application.put_env(:cympho, :company_import_transfer_spool_root, previous_root)
      else
        Application.delete_env(:cympho, :company_import_transfer_spool_root)
      end
    end)

    {conn, user, company} =
      register_and_log_in_user(conn, %{role: "admin", is_board_member: true})

    package = company.id |> Companies.export_company() |> Jason.encode!()

    {:ok, conn: conn, user: user, company: company, package: package, spool_root: spool_root}
  end

  test "uploads parts out of order, resumes, previews, and applies once", %{
    conn: conn,
    package: package,
    company: source_company,
    spool_root: spool_root
  } do
    {manifest, parts} = manifest_for(package, 3)

    declared = post(conn, transfer_path(), manifest)
    body = json_response(declared, 201)
    transfer_id = body["transfer_id"]

    assert body["status"] == "uploading"
    refute body["restore_receipt_available"]
    assert body["missing_parts"] == [0, 1, 2]
    refute Map.has_key?(body, "spool_path")

    assert %{"index" => 2, "already_completed" => false} =
             declared
             |> recycle()
             |> put_part(transfer_id, 2, Enum.at(parts, 2))
             |> json_response(200)

    assert %{"index" => 0, "already_completed" => false} =
             declared
             |> recycle()
             |> put_part(transfer_id, 0, Enum.at(parts, 0))
             |> json_response(200)

    midway = declared |> recycle() |> get(transfer_path(transfer_id))

    assert %{
             "transfer_id" => ^transfer_id,
             "uploaded_parts" => 2,
             "missing_parts" => [1]
           } = json_response(midway, 200)

    resumed = midway |> recycle() |> post(transfer_path(), manifest)

    assert %{
             "transfer_id" => ^transfer_id,
             "uploaded_parts" => 2,
             "missing_parts" => [1]
           } = json_response(resumed, 200)

    completed = resumed |> recycle() |> put_part(transfer_id, 1, Enum.at(parts, 1))
    assert %{"index" => 1} = json_response(completed, 200)

    # The declaration persisted the default suffix strategy. Later request
    # params cannot swap it to fail for either preview or apply.
    previewed =
      completed
      |> recycle()
      |> post(transfer_path(transfer_id, "preview"), %{"slug_strategy" => "fail"})

    assert %{"data" => %{"version" => 1}} = json_response(previewed, 200)

    applied =
      completed
      |> recycle()
      |> post(transfer_path(transfer_id, "apply"), %{"slug_strategy" => "fail"})

    imported_id = get_in(json_response(applied, 201), ["data", "id"])

    assert is_binary(imported_id)
    refute imported_id == source_company.id
    refute File.exists?(Path.join(spool_root, transfer_id))

    assert %{
             "status" => "completed",
             "already_completed" => true,
             "imported_company_id" => ^imported_id
           } =
             applied
             |> recycle()
             |> get(transfer_path(transfer_id))
             |> json_response(200)

    duplicate = applied |> recycle() |> post(transfer_path(transfer_id, "apply"), %{})
    assert %{"error" => "Transfer is not open for this operation"} = json_response(duplicate, 409)
  end

  test "completed status and redeclaration return the persisted secret restore receipt", %{
    conn: conn,
    company: source_company
  } do
    {:ok, _secret} =
      Cympho.Secrets.create_secret(%{
        company_id: source_company.id,
        scope: "company",
        key: "RESTORE_AFTER_IMPORT",
        value: "never-return-this-value",
        description: "Imported runtime credential"
      })

    package = source_company.id |> Companies.export_company() |> Jason.encode!()
    {manifest, [part]} = manifest_for(package, 1)
    declared = post(conn, transfer_path(), manifest)
    transfer_id = json_response(declared, 201)["transfer_id"]
    uploaded = declared |> recycle() |> put_part(transfer_id, 0, part)

    applied = uploaded |> recycle() |> post(transfer_path(transfer_id, "apply"), %{})
    applied_body = json_response(applied, 201)
    assert [%{"key" => "RESTORE_AFTER_IMPORT"} = receipt] = applied_body["secrets_to_restore"]
    refute Map.has_key?(receipt, "value")
    refute inspect(receipt) =~ "never-return-this-value"

    status_body =
      applied
      |> recycle()
      |> get(transfer_path(transfer_id))
      |> json_response(200)

    assert status_body["secrets_to_restore"] == applied_body["secrets_to_restore"]

    redeclared = applied |> recycle() |> post(transfer_path(), manifest)
    redeclared_body = json_response(redeclared, 200)
    assert redeclared_body["already_completed"]
    assert redeclared_body["restore_receipt_available"]
    assert redeclared_body["secrets_to_restore"] == applied_body["secrets_to_restore"]
  end

  test "apply record bounds reject before claiming or writing a company", %{
    conn: conn,
    package: package
  } do
    previous = Application.get_env(:cympho, :company_import_transfer_max_package_records)
    Application.put_env(:cympho, :company_import_transfer_max_package_records, 1)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:cympho, :company_import_transfer_max_package_records)
      else
        Application.put_env(:cympho, :company_import_transfer_max_package_records, previous)
      end
    end)

    {manifest, [part]} = manifest_for(package, 1)
    declared = post(conn, transfer_path(), manifest)
    transfer_id = json_response(declared, 201)["transfer_id"]
    uploaded = declared |> recycle() |> put_part(transfer_id, 0, part)
    company_count = Repo.aggregate(Cympho.Companies.Company, :count)

    assert %{"error" => "Import package exceeds configured record capacity"} =
             uploaded
             |> recycle()
             |> post(transfer_path(transfer_id, "apply"), %{})
             |> json_response(422)

    assert Repo.aggregate(Cympho.Companies.Company, :count) == company_count
    assert Repo.get!(ImportTransfer, transfer_id).status == "failed"
  end

  test "streams request bodies in bounded 64 KiB reads", %{conn: conn} do
    package = Jason.encode!(%{"padding" => String.duplicate("x", 150_000)})
    {manifest, [part]} = manifest_for(package, 1)

    declared = post(conn, transfer_path(), manifest)
    transfer_id = json_response(declared, 201)["transfer_id"]

    # ImportTransferSpool rejects reader chunks over 64 KiB. A 150 KiB raw
    # request succeeding proves the controller pulled it through multiple
    # bounded reads rather than handing the whole body to the spool.
    uploaded = declared |> recycle() |> put_part(transfer_id, 0, part)
    assert %{"index" => 0, "already_completed" => false} = json_response(uploaded, 200)
  end

  test "requires a user JWT", %{package: package} do
    {manifest, _parts} = manifest_for(package, 1)

    assert %{"errors" => [%{"detail" => "Authentication required"}]} =
             build_conn()
             |> post(transfer_path(), manifest)
             |> json_response(401)
  end

  test "binds declarations to the authorizing company and ignores a forged target", %{
    conn: conn,
    user: user,
    company: company,
    package: package
  } do
    {:ok, foreign_company} =
      Companies.create_company(%{
        name: "Forged target",
        slug: "forged-target-#{System.unique_integer([:positive])}"
      })

    {manifest, _parts} = manifest_for(package, 1)
    manifest = Map.put(manifest, "target_company_id", foreign_company.id)
    response = post(conn, transfer_path(), manifest)
    transfer_id = json_response(response, 201)["transfer_id"]

    assert %ImportTransfer{
             owner_user_id: owner_user_id,
             target_company_id: target_company_id
           } = Repo.get!(ImportTransfer, transfer_id)

    assert owner_user_id == user.id
    assert target_company_id == company.id
  end

  test "requires writable board membership", %{package: package} do
    {manifest, _parts} = manifest_for(package, 1)

    {non_board_conn, _user, _company} =
      register_and_log_in_user(build_conn(), %{role: "admin", is_board_member: false})

    assert %{"errors" => [%{"detail" => "No board members configured for this company"}]} =
             non_board_conn
             |> post(transfer_path(), manifest)
             |> json_response(403)
  end

  test "browser transfer declaration rejects a missing CSRF token", %{
    conn: conn,
    package: package
  } do
    {manifest, _parts} = manifest_for(package, 1)

    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      conn
      |> enforce_csrf()
      |> delete_req_header("authorization")
      |> post("/companies/import/transfers", manifest)
    end
  end

  test "browser transfer declaration rejects an invalid CSRF token", %{
    conn: conn,
    package: package
  } do
    {manifest, _parts} = manifest_for(package, 1)

    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      conn
      |> enforce_csrf()
      |> delete_req_header("authorization")
      |> put_req_header("x-csrf-token", "invalid-token")
      |> post("/companies/import/transfers", manifest)
    end
  end

  test "re-upload is idempotent and cancellation makes the transfer terminal", %{
    conn: conn,
    package: package
  } do
    {manifest, [part]} = manifest_for(package, 1)
    declared = post(conn, transfer_path(), manifest)
    transfer_id = json_response(declared, 201)["transfer_id"]

    first = declared |> recycle() |> put_part(transfer_id, 0, part)
    assert %{"already_completed" => false} = json_response(first, 200)

    second = first |> recycle() |> put_part(transfer_id, 0, part)
    assert %{"already_completed" => true} = json_response(second, 200)

    cancelled = second |> recycle() |> delete(transfer_path(transfer_id))
    assert response(cancelled, 204) == ""

    assert %{"error" => "Transfer is not open for this operation"} =
             cancelled
             |> recycle()
             |> put_part(transfer_id, 0, part)
             |> json_response(409)
  end

  test "an active part upload lease returns retryable HTTP 425", %{
    conn: conn,
    package: package
  } do
    {manifest, [part]} = manifest_for(package, 1)
    declared = post(conn, transfer_path(), manifest)
    transfer_id = json_response(declared, 201)["transfer_id"]
    part_row = Repo.get_by!(ImportTransferPart, transfer_id: transfer_id, position: 0)

    part_row
    |> Ecto.Changeset.change(
      upload_claim_token: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false),
      upload_lease_expires_at: DateTime.add(DateTime.utc_now(), 30, :second)
    )
    |> Repo.update!()

    response = declared |> recycle() |> put_part(transfer_id, 0, part)
    assert get_resp_header(response, "retry-after") == ["1"]

    assert %{"error" => "Transfer part upload is already in progress"} =
             json_response(response, 425)
  end

  test "rejects wrong content types without consuming them", %{conn: conn, package: package} do
    {manifest, [part]} = manifest_for(package, 1)
    declared = post(conn, transfer_path(), manifest)
    transfer_id = json_response(declared, 201)["transfer_id"]

    response =
      declared
      |> recycle()
      |> put_req_header("content-type", "application/json")
      |> put(transfer_path(transfer_id, "parts/0"), Jason.encode!(%{part: Base.encode64(part)}))

    assert %{"error" => "Expected application/octet-stream"} = json_response(response, 415)

    assert %{"uploaded_parts" => 0, "missing_parts" => [0]} =
             response
             |> recycle()
             |> get(transfer_path(transfer_id))
             |> json_response(200)
  end

  test "rejects hash and size mismatches without recording a part", %{
    conn: conn,
    package: package
  } do
    {manifest, [part]} = manifest_for(package, 1)

    hash_declared = post(conn, transfer_path(), manifest)
    hash_id = json_response(hash_declared, 201)["transfer_id"]
    <<first, rest::binary>> = part
    wrong_bytes = <<Bitwise.bxor(first, 1), rest::binary>>

    assert %{"error" => "Part hash does not match its declaration"} =
             hash_declared
             |> recycle()
             |> put_part(hash_id, 0, wrong_bytes)
             |> json_response(422)

    assert %{"uploaded_parts" => 0, "missing_parts" => [0]} =
             hash_declared
             |> recycle()
             |> get(transfer_path(hash_id))
             |> json_response(200)

    size_manifest = Map.put(manifest, "idempotency_key", idempotency_key())
    size_declared = hash_declared |> recycle() |> post(transfer_path(), size_manifest)
    size_id = json_response(size_declared, 201)["transfer_id"]

    assert %{"error" => "Part exceeds its declared size"} =
             size_declared
             |> recycle()
             |> put_part(size_id, 0, part <> "x")
             |> json_response(413)

    short_manifest = Map.put(manifest, "idempotency_key", idempotency_key())
    short_declared = size_declared |> recycle() |> post(transfer_path(), short_manifest)
    short_id = json_response(short_declared, 201)["transfer_id"]

    assert %{"error" => "Part size does not match its declaration"} =
             short_declared
             |> recycle()
             |> put_part(short_id, 0, binary_part(part, 0, byte_size(part) - 1))
             |> json_response(422)
  end

  test "missing parts block preview and apply", %{conn: conn, package: package} do
    {manifest, _parts} = manifest_for(package, 2)
    declared = post(conn, transfer_path(), manifest)
    transfer_id = json_response(declared, 201)["transfer_id"]

    assert %{"error" => "Transfer still has missing parts"} =
             declared
             |> recycle()
             |> post(transfer_path(transfer_id, "preview"), %{})
             |> json_response(409)

    assert %{"error" => "Transfer still has missing parts"} =
             declared
             |> recycle()
             |> post(transfer_path(transfer_id, "apply"), %{})
             |> json_response(409)
  end

  test "malformed and foreign transfer IDs are indistinguishable from missing", %{
    conn: conn,
    package: package
  } do
    {manifest, [part]} = manifest_for(package, 1)
    declared = post(conn, transfer_path(), manifest)
    transfer_id = json_response(declared, 201)["transfer_id"]

    {foreign_conn, _foreign_user, _foreign_company} =
      register_and_log_in_user(build_conn(), %{role: "admin", is_board_member: true})

    assert json_response(get(foreign_conn, transfer_path(transfer_id)), 404)
    assert json_response(get(conn, transfer_path("not-a-uuid")), 404)

    # Authorization is checked before media type so a foreign actor cannot use
    # response differences to probe whether a transfer exists.
    foreign_upload =
      foreign_conn
      |> put_req_header("content-type", "text/plain")
      |> put(transfer_path(transfer_id, "parts/0"), part)

    assert json_response(foreign_upload, 404)

    malformed_upload =
      conn
      |> recycle()
      |> put_req_header("content-type", "application/octet-stream")
      |> put(transfer_path("not-a-uuid", "parts/0"), part)

    assert json_response(malformed_upload, 404)
  end

  test "the same actor cannot operate a transfer through another current company", %{
    conn: conn,
    user: user,
    package: package
  } do
    {manifest, [part]} = manifest_for(package, 1)
    declared = post(conn, transfer_path(), manifest)
    transfer_id = json_response(declared, 201)["transfer_id"]

    uploaded = declared |> recycle() |> put_part(transfer_id, 0, part)
    assert json_response(uploaded, 200)

    {:ok, other_company} =
      Companies.create_company(%{
        name: "Other current company",
        slug: "other-transfer-current-#{System.unique_integer([:positive])}"
      })

    {:ok, _membership} =
      Companies.create_membership(%{
        user_id: user.id,
        company_id: other_company.id,
        role: "owner",
        is_board_member: true
      })

    {:ok, other_token} = Cympho.UserAuthJWT.generate_token(user, other_company.id)

    other_conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> other_token)

    assert json_response(get(other_conn, transfer_path(transfer_id)), 404)

    assert json_response(
             other_conn
             |> recycle()
             |> put_part(transfer_id, 0, part),
             404
           )

    assert json_response(
             other_conn
             |> recycle()
             |> post(transfer_path(transfer_id, "preview"), %{}),
             404
           )

    assert json_response(
             other_conn
             |> recycle()
             |> post(transfer_path(transfer_id, "apply"), %{}),
             404
           )

    assert json_response(
             other_conn
             |> recycle()
             |> delete(transfer_path(transfer_id)),
             404
           )

    assert %{"status" => "ready", "missing_parts" => []} =
             uploaded
             |> recycle()
             |> get(transfer_path(transfer_id))
             |> json_response(200)
  end

  test "only one concurrent apply imports the company", %{conn: conn, package: package} do
    {manifest, [part]} = manifest_for(package, 1)
    declared = post(conn, transfer_path(), manifest)
    transfer_id = json_response(declared, 201)["transfer_id"]
    uploaded = declared |> recycle() |> put_part(transfer_id, 0, part)
    assert json_response(uploaded, 200)

    parent = self()
    apply_path = transfer_path(transfer_id, "apply")

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())
          uploaded |> recycle() |> post(apply_path, %{}) |> Map.fetch!(:status)
        end)
      end

    assert tasks |> Enum.map(&Task.await(&1, 15_000)) |> Enum.sort() == [201, 409]
  end

  test "preview and apply fail fast while decoded import processing is busy", %{
    conn: conn,
    package: package
  } do
    {manifest, [part]} = manifest_for(package, 1)
    declared = post(conn, transfer_path(), manifest)
    transfer_id = json_response(declared, 201)["transfer_id"]
    uploaded = declared |> recycle() |> put_part(transfer_id, 0, part)
    assert json_response(uploaded, 200)

    {:ok, token} = ImportDecodeAdmission.checkout()

    # Raw uploads are intentionally outside this heavy-decode admission slot.
    second_manifest = Map.put(manifest, "idempotency_key", idempotency_key())
    second_declared = uploaded |> recycle() |> post(transfer_path(), second_manifest)
    second_id = json_response(second_declared, 201)["transfer_id"]
    assert second_declared |> recycle() |> put_part(second_id, 0, part) |> json_response(200)

    preview = uploaded |> recycle() |> post(transfer_path(transfer_id, "preview"), %{})
    assert get_resp_header(preview, "retry-after") == ["5"]
    assert %{"error" => "Import processing is currently busy"} = json_response(preview, 429)
    assert Repo.get!(ImportTransfer, transfer_id).status == "ready"

    apply = uploaded |> recycle() |> post(transfer_path(transfer_id, "apply"), %{})
    assert get_resp_header(apply, "retry-after") == ["5"]
    assert %{"error" => "Import processing is currently busy"} = json_response(apply, 429)

    assert %ImportTransfer{status: "failed", apply_claim_token: nil} =
             Repo.get!(ImportTransfer, transfer_id)

    assert :ok = ImportDecodeAdmission.release(token)

    assert uploaded
           |> recycle()
           |> post(transfer_path(transfer_id, "preview"), %{})
           |> json_response(200)

    assert uploaded
           |> recycle()
           |> post(transfer_path(transfer_id, "apply"), %{})
           |> json_response(201)
  end

  defp put_part(conn, transfer_id, position, bytes) do
    conn
    |> put_req_header("content-type", "application/octet-stream")
    |> put(transfer_path(transfer_id, "parts/#{position}"), bytes)
  end

  defp transfer_path, do: "/api/companies/import/transfers"
  defp transfer_path(id), do: transfer_path() <> "/" <> id
  defp transfer_path(id, suffix), do: transfer_path(id) <> "/" <> suffix

  defp manifest_for(binary, part_count) when part_count > 0 do
    part_size = div(byte_size(binary) + part_count - 1, part_count)

    parts =
      binary
      |> :binary.bin_to_list()
      |> Enum.chunk_every(part_size)
      |> Enum.map(&:erlang.list_to_binary/1)

    manifest = %{
      "idempotency_key" => idempotency_key(),
      "total_bytes" => byte_size(binary),
      "part_size_bytes" => part_size,
      "file_sha256" => sha256(binary),
      "parts" =>
        parts
        |> Enum.with_index()
        |> Enum.map(fn {part, position} ->
          %{"position" => position, "byte_size" => byte_size(part), "sha256" => sha256(part)}
        end)
    }

    {manifest, parts}
  end

  defp sha256(binary),
    do: :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)

  defp idempotency_key,
    do:
      "controller-#{System.unique_integer([:positive])}-#{Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)}"

  defp enforce_csrf(conn) do
    %{conn | private: Map.delete(conn.private, :plug_skip_csrf_protection)}
  end
end
