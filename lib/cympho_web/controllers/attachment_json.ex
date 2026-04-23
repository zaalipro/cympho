defmodule CymphoWeb.AttachmentJSON do
  alias Cympho.Attachments.Attachment

  def index(%{attachments: attachments}) do
    %{data: Enum.map(attachments, &data/1)}
  end

  def show(%{attachment: %Attachment{} = attachment}) do
    %{data: data(attachment)}
  end

  defp data(%Attachment{} = attachment) do
    %{
      id: attachment.id,
      filename: attachment.filename,
      content_type: attachment.content_type,
      file_size: attachment.file_size,
      issue_id: attachment.issue_id,
      comment_id: attachment.comment_id,
      inserted_at: attachment.inserted_at,
      updated_at: attachment.updated_at
    }
  end
end
