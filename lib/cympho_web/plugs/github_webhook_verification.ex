defmodule CymphoWeb.Plugs.GithubWebhookVerification do
  @moduledoc """
  Plug that extracts and prepares GitHub webhook signature verification.

  The actual verification is performed in the controller once we have
  access to the project's webhook secret (derived from the issue's project).
  """
  import Plug.Conn

  @signature_header "x-hub-signature-256"

  def init(opts), do: opts

  def call(conn, _opts) do
    signature = get_signature(conn)
    {:ok, body, _} = read_body(conn)

    conn
    |> assign(:github_webhook_signature, signature)
    |> assign(:github_webhook_raw_body, body)
  end

  defp get_signature(conn) do
    case get_req_header(conn, @signature_header) do
      [sig | _] -> sig
      [] -> nil
    end
  end
end