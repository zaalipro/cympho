defmodule Cympho.T1Review.SecurityAgrentingTransportErrorTest do
  # Finding security-astra-missed-1: Agrenting transport errors still disclose
  # configured credentials in the marketplace.
  use ExUnit.Case, async: false

  alias Cympho.Agrenting.Client

  test "a transport error does not carry the configured API key" do
    # save_company_config trims the ends, so the stray control character sits
    # inside the key (e.g. a key pasted across a line wrap).
    api_key = "agrenting-sentinel-0123\n4567"

    # A listening socket accepts the TCP handshake; Mint then refuses to
    # encode the Authorization header and returns Mint.HTTPError.
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(listen)
    on_exit(fn -> :gen_tcp.close(listen) end)

    assert {:error, reason} =
             Client.list_agents(%{
               "api_key" => api_key,
               "base_url" => "http://127.0.0.1:#{port}"
             })

    # The marketplace shows "Agrenting request failed: #{inspect(reason)}".
    refute inspect(reason) =~ "agrenting-sentinel"
  end
end
