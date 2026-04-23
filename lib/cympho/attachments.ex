defmodule Cympho.Attachments do
  import Ecto.Query, warn: false
  alias Cympho.Repo
  alias Cympho.Attachments.Attachment

  @upload_dir Application.compile_env(:cympho, :uploads_dir, "priv/static/uploads")

  def list_attachments(issue_id) do
    Attachment
    |> where(issue_id: ^issue_id)
    |> order_by([a], asc: a.inserted_at)
    |> Repo.all()
  end

  def get_attachment!(id), do: Repo.get!(Attachment, id)

  def get_attachment(id) do
    case Repo.get(Attachment, id) do
      nil -> {:error, :not_found}
      attachment -> {:ok, attachment}
    end
  end

  def create_attachment(attrs \\ %{}) do
    %Attachment{}
    |> Attachment.changeset(attrs)
    |> Repo.insert()
  end

  def delete_attachment(%Attachment{} = attachment) do
    case Repo.delete(attachment) do
      {:ok, attachment} ->
        delete_file(attachment.path)
        {:ok, attachment}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

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

  def read_file(%Attachment{} = attachment) do
    full_path = Path.join(@upload_dir, attachment.path)
    File.read(full_path)
  end

  defp delete_file(relative_path) do
    full_path = Path.join(@upload_dir, relative_path)
    File.rm(full_path)
  end

  defp validate_uuid(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_issue_id}
    end
  end

  defp validate_uuid(_), do: {:error, :invalid_issue_id}
end
