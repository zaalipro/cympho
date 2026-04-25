defmodule Cympho.Attachments do
  import Ecto.Query, warn: false
  alias Cympho.Repo
  alias Cympho.Attachments.Attachment
  alias Cympho.Attachments.Storage

  @storage_backend Storage.backend()

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
        @storage_backend.delete_file(attachment.path)
        {:ok, attachment}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def store_file(%Plug.Upload{} = upload, issue_id) do
    @storage_backend.store_file(upload, issue_id)
  end

  def read_file(%Attachment{} = attachment) do
    @storage_backend.read_file(attachment.path)
  end

  def public_url(%Attachment{} = attachment) do
    @storage_backend.public_url(attachment.path)
  end
end
