defmodule Cympho.Attachments.Storage do
  @moduledoc """
  Behavior for attachment storage backends.

  Storage backends must implement these callbacks to support
  storing, reading, and deleting attachment files.
  """

  alias Cympho.Attachments.Storage.LocalStorage
  alias Cympho.Attachments.Storage.S3Storage

  @doc """
  Store a file upload and return the relative path/key.

  Should return `{:ok, relative_path}` on success or `{:error, reason}` on failure.
  """
  @callback store_file(upload :: Plug.Upload.t(), issue_id :: String.t()) ::
              {:ok, String.t()} | {:error, term()}

  @doc """
  Read a file by its relative path/key.

  Should return `{:ok, binary}` on success or `{:error, reason}` on failure.
  """
  @callback read_file(relative_path :: String.t()) :: {:ok, binary()} | {:error, term()}

  @doc """
  Delete a file by its relative path/key.

  Should return `:ok` on success or `{:error, reason}` on failure.
  """
  @callback delete_file(relative_path :: String.t()) :: :ok | {:error, term()}

  @doc """
  Get the public URL for a file by its relative path/key.

  Should return a string URL or `nil` if not applicable.
  """
  @callback public_url(relative_path :: String.t()) :: String.t() | nil

  @doc """
  Returns the configured storage backend module.

  Defaults to LocalStorage. Can be configured via:

      config :cympho, :storage_backend, Cympho.Attachments.Storage.S3Storage
  """
  def backend do
    Application.get_env(:cympho, :storage_backend, LocalStorage)
  end
end
