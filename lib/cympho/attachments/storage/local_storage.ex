defmodule Cympho.Attachments.Storage.LocalStorage do
  @moduledoc """
  Local filesystem storage backend for attachments.

  Stores files in `priv/static/uploads` organized by issue_id.
  """

  @behaviour Cympho.Attachments.Storage

  @upload_dir Application.compile_env(:cympho, :uploads_dir, "priv/static/uploads")

  @impl true
  def store_file(%Plug.Upload{filename: filename, path: tmp_path}, issue_id) do
    with {:ok, safe_id} <- validate_uuid(issue_id) do
      ext = Path.extname(filename)
      unique_name = "#{Ecto.UUID.generate()}#{ext}"
      dest_dir = Path.join(@upload_dir, safe_id)
      dest_path = Path.join(dest_dir, unique_name)

      with :ok <- File.mkdir_p(dest_dir),
           {:ok, _} <- File.copy(tmp_path, dest_path) do
        {:ok, Path.join(safe_id, unique_name)}
      end
    end
  end

  @impl true
  def read_file(relative_path) do
    full_path = Path.join(@upload_dir, relative_path)
    File.read(full_path)
  end

  @impl true
  def delete_file(relative_path) do
    full_path = Path.join(@upload_dir, relative_path)
    File.rm(full_path)
  end

  @impl true
  def public_url(relative_path) do
    "/uploads/#{relative_path}"
  end

  defp validate_uuid(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_issue_id}
    end
  end

  defp validate_uuid(_), do: {:error, :invalid_issue_id}
end
