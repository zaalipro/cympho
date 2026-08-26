defmodule CymphoWeb.CompanyImportTransferController do
  use CymphoWeb, :controller

  alias Cympho.Companies
  alias Cympho.Companies.ImportDecodeAdmission
  alias Cympho.Companies.ImportTransfers

  @read_length 64 * 1024

  def declare(conn, params) do
    declaration =
      params
      |> Map.delete(:target_company_id)
      |> Map.put("target_company_id", conn.assigns.current_company.id)

    with {:ok, result} <-
           ImportTransfers.declare(conn.assigns.current_user.id, declaration) do
      conn
      |> put_status(if(result.resumed, do: :ok, else: :created))
      |> json(transfer_status(result))
    else
      error -> transfer_error(conn, error)
    end
  end

  def status(conn, %{"id" => id}) do
    with :ok <- valid_transfer_id(id),
         {:ok, _transfer} <- authorize_current_company(conn, id),
         {:ok, result} <- ImportTransfers.status(id, conn.assigns.current_user.id) do
      json(conn, transfer_status(result))
    else
      error -> transfer_error(conn, error)
    end
  end

  def put_part(conn, %{"id" => id, "position" => position}) do
    with :ok <- valid_transfer_id(id),
         {:ok, _transfer} <- authorize_current_company(conn, id),
         :ok <- octet_stream_request(conn),
         {:ok, position} <- parse_position(position) do
      stream_part(conn, id, position)
    else
      error -> transfer_error(conn, error)
    end
  end

  def preview(conn, %{"id" => id}) do
    with :ok <- valid_transfer_id(id),
         {:ok, _transfer} <- authorize_current_company(conn, id) do
      with_decode_slot(conn, fn ->
        with {:ok, progress} <- ImportTransfers.status(id, conn.assigns.current_user.id),
             {:ok, package} <- ImportTransfers.decode(id, conn.assigns.current_user.id),
             {:ok, preview} <-
               Companies.preview_import(package,
                 slug_strategy: transfer_slug_strategy(progress.transfer)
               ) do
          json(conn, %{data: preview})
        else
          error -> transfer_error(conn, error)
        end
      end)
    else
      error -> transfer_error(conn, error)
    end
  end

  def apply(conn, %{"id" => id}) do
    user_id = conn.assigns.current_user.id

    with :ok <- valid_transfer_id(id),
         {:ok, authorized_transfer} <- authorize_current_company(conn, id),
         :ok <- apply_precheck(authorized_transfer),
         {:ok, transfer} <- ImportTransfers.claim_apply(id, user_id) do
      case ImportDecodeAdmission.checkout() do
        {:ok, admission_token} ->
          try do
            apply_claimed_transfer(conn, id, user_id, transfer)
          after
            ImportDecodeAdmission.release(admission_token)
          end

        {:error, :busy} ->
          _ =
            ImportTransfers.fail(
              id,
              user_id,
              transfer.apply_claim_token,
              "Import processing is currently busy."
            )

          transfer_error(conn, :decode_busy)
      end
    else
      error -> transfer_error(conn, error)
    end
  end

  def cancel(conn, %{"id" => id}) do
    with :ok <- valid_transfer_id(id),
         {:ok, _transfer} <- authorize_current_company(conn, id),
         {:ok, _transfer} <- ImportTransfers.cancel(id, conn.assigns.current_user.id) do
      send_resp(conn, :no_content, "")
    else
      error -> transfer_error(conn, error)
    end
  end

  defp stream_part(conn, id, position) do
    reader = fn reader_conn ->
      case Plug.Conn.read_body(reader_conn, length: @read_length, read_length: @read_length) do
        {:ok, "", _next_conn} ->
          :eof

        {:ok, bytes, next_conn} ->
          {:ok, bytes, next_conn}

        {:more, bytes, next_conn} ->
          {:ok, bytes, next_conn}

        {:error, reason} ->
          {:error, reason}
      end
    end

    result =
      ImportTransfers.put_part_from_reader(
        id,
        conn.assigns.current_user.id,
        position,
        reader,
        reader_state: conn
      )

    case result do
      {:ok, part} ->
        json(part.reader_state || conn, %{
          ok: true,
          index: part.index,
          already_completed: part.already_completed
        })

      error ->
        transfer_error(conn, error)
    end
  end

  defp apply_claimed_transfer(conn, id, user_id, transfer) do
    result =
      with {:ok, package} <- ImportTransfers.decode(id, user_id),
           {:ok, preview} <-
             Companies.preview_import(package,
               slug_strategy: transfer_slug_strategy(transfer)
             ),
           :ok <- ImportTransfers.validate_apply_capacity(preview),
           {:ok, import_result} <-
             Companies.import_company_for_owner(package, user_id,
               slug_strategy: transfer_slug_strategy(transfer),
               after_import: fn import_result ->
                 ImportTransfers.complete_in_transaction(
                   Cympho.Repo,
                   id,
                   user_id,
                   transfer.apply_claim_token,
                   import_result.company.id,
                   import_result.secrets_to_restore
                 )
               end
             ) do
        {:ok, import_result}
      end

    case result do
      {:ok, import_result} ->
        # Completion committed in the same transaction as the company graph.
        # Spool deletion is deliberately best-effort and cannot turn that
        # durable success into an import failure; the sweeper is the fallback.
        _ = ImportTransfers.cleanup_completed_spool(id, user_id)

        conn
        |> put_status(:created)
        |> json(%{
          data: company_data(import_result.company),
          secrets_to_restore: import_result.secrets_to_restore
        })

      error ->
        _ = ImportTransfers.fail(id, user_id, transfer.apply_claim_token, "Import failed.")
        transfer_error(conn, error)
    end
  rescue
    _exception ->
      _ = ImportTransfers.fail(id, user_id, transfer.apply_claim_token, "Import failed.")
      transfer_error(conn, {:error, :import_failed})
  end

  defp transfer_status(result) do
    transfer = result.transfer

    %{
      transfer_id: transfer.id,
      status: transfer.status,
      already_completed: Map.get(result, :already_completed, transfer.status == "completed"),
      imported_company_id: transfer.imported_company_id,
      secrets_to_restore: transfer.secrets_to_restore,
      restore_receipt_available: transfer.status == "completed",
      total_parts: result.total_parts,
      uploaded_parts: result.uploaded_parts,
      missing_parts: result.missing_parts
    }
  end

  defp company_data(company) do
    %{id: company.id, name: company.name, slug: company.slug}
  end

  defp transfer_slug_strategy(%{import_options: %{"slug_strategy" => "fail"}}), do: :fail
  defp transfer_slug_strategy(_transfer), do: :suffix

  defp apply_precheck(%{status: "completed"}), do: {:error, :conflict}
  defp apply_precheck(_transfer), do: :ok

  defp with_decode_slot(conn, operation) do
    case ImportDecodeAdmission.checkout() do
      {:ok, token} ->
        try do
          operation.()
        after
          ImportDecodeAdmission.release(token)
        end

      {:error, :busy} ->
        transfer_error(conn, :decode_busy)
    end
  end

  defp valid_transfer_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, _uuid} -> :ok
      :error -> {:error, :not_found}
    end
  end

  defp authorize_current_company(conn, id) do
    with {:ok, transfer} <- ImportTransfers.authorize(id, conn.assigns.current_user.id),
         %{id: company_id} <- conn.assigns[:current_company],
         true <- transfer.target_company_id == company_id do
      {:ok, transfer}
    else
      _ -> {:error, :not_found}
    end
  end

  defp parse_position(value) when is_integer(value) and value >= 0, do: {:ok, value}

  defp parse_position(value) when is_binary(value) do
    case Integer.parse(value) do
      {position, ""} when position >= 0 -> {:ok, position}
      _ -> {:error, :not_found}
    end
  end

  defp parse_position(_value), do: {:error, :not_found}

  defp octet_stream_request(conn) do
    content_type =
      conn
      |> get_req_header("content-type")
      |> List.first()
      |> to_string()
      |> String.split(";", parts: 2)
      |> List.first()
      |> String.trim()
      |> String.downcase()

    if content_type == "application/octet-stream" do
      :ok
    else
      {:error, :unsupported_media_type}
    end
  end

  defp transfer_error(conn, {:error, reason}), do: transfer_error(conn, reason)

  defp transfer_error(conn, :not_found),
    do: error_response(conn, :not_found, "Transfer not found")

  defp transfer_error(conn, :unsupported_media_type),
    do: error_response(conn, :unsupported_media_type, "Expected application/octet-stream")

  defp transfer_error(conn, :capacity_exceeded) do
    conn
    |> put_resp_header("retry-after", "5")
    |> error_response(:too_many_requests, "Import transfer capacity is currently full")
  end

  defp transfer_error(conn, :decode_busy) do
    conn
    |> put_resp_header("retry-after", "5")
    |> error_response(:too_many_requests, "Import processing is currently busy")
  end

  defp transfer_error(conn, :upload_in_progress) do
    conn
    |> put_resp_header("retry-after", "1")
    |> error_response(:too_early, "Transfer part upload is already in progress")
  end

  defp transfer_error(conn, :package_capacity_exceeded),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "Import package exceeds configured record capacity"
      )

  defp transfer_error(conn, reason)
       when reason in [:manifest_conflict, :conflict, :not_ready, :missing_parts],
       do: error_response(conn, :conflict, error_message(reason))

  defp transfer_error(conn, reason)
       when reason in [:too_large, :part_too_large, :size_exceeded],
       do: error_response(conn, :request_entity_too_large, "Part exceeds its declared size")

  defp transfer_error(conn, reason)
       when reason in [
              :invalid_manifest,
              :invalid_part,
              :invalid_size,
              :size_mismatch,
              :part_size_mismatch,
              :hash_mismatch,
              :part_sha256_mismatch,
              :file_sha256_mismatch,
              :integrity_error,
              :invalid_json,
              :invalid_json_package
            ],
       do: error_response(conn, :unprocessable_entity, error_message(reason))

  defp transfer_error(conn, %Ecto.Changeset{}),
    do: error_response(conn, :unprocessable_entity, "Invalid transfer declaration")

  defp transfer_error(conn, %{errors: errors}) when is_list(errors),
    do: error_response(conn, :unprocessable_entity, "Transfer package validation failed")

  defp transfer_error(conn, reason) when is_binary(reason),
    do: error_response(conn, :unprocessable_entity, "Import failed")

  defp transfer_error(conn, :import_failed),
    do: error_response(conn, :unprocessable_entity, "Import failed")

  defp transfer_error(conn, _reason),
    do: error_response(conn, :bad_request, "Transfer request failed")

  defp error_message(:manifest_conflict), do: "Transfer declaration conflicts with prior content"
  defp error_message(:conflict), do: "Transfer is not open for this operation"
  defp error_message(:not_ready), do: "Transfer still has missing parts"
  defp error_message(:missing_parts), do: "Transfer still has missing parts"
  defp error_message(:invalid_manifest), do: "Invalid transfer declaration"
  defp error_message(:invalid_part), do: "Part is not declared by this transfer"
  defp error_message(:invalid_size), do: "Part size is invalid"
  defp error_message(:size_mismatch), do: "Part size does not match its declaration"
  defp error_message(:part_size_mismatch), do: "Part size does not match its declaration"
  defp error_message(:hash_mismatch), do: "Part hash does not match its declaration"
  defp error_message(:part_sha256_mismatch), do: "Part hash does not match its declaration"
  defp error_message(:file_sha256_mismatch), do: "Transfer integrity verification failed"
  defp error_message(:integrity_error), do: "Transfer integrity verification failed"
  defp error_message(:invalid_json), do: "Transfer is not a valid JSON package"
  defp error_message(:invalid_json_package), do: "Transfer is not a valid JSON package"

  defp error_response(conn, status, message) do
    conn
    |> put_status(status)
    |> json(%{error: message})
  end
end
