ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Cympho.Repo, :manual)

# Suppress Ecto sandbox disconnect noise during test cleanup.
# These occur when Task.Supervised processes outlive the test process
# that owned the sandbox connection — a harmless cleanup artifact.
try do
  :logger.add_handler_filter(:default, :sandbox_disconnect_filter, {fn
    %{msg: {:string, msg}}, _arg ->
      text = msg |> List.to_string()

      if String.contains?(text, "disconnected") and
           String.contains?(text, "DBConnection.ConnectionError") do
        :stop
      else
        :log
      end

    %{msg: msg}, _arg when is_binary(msg) ->
      if String.contains?(msg, "disconnected") and
           String.contains?(msg, "DBConnection.ConnectionError") do
        :stop
      else
        :log
      end

    _log_event, _arg ->
      :log
  end, nil})
rescue
  _ -> :ok
end
