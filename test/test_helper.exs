ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Cympho.Repo, :manual)

# Suppress Ecto sandbox disconnect noise during test cleanup.
# These occur when Task.Supervised processes outlive the test process
# that owned the sandbox connection — a harmless cleanup artifact.
# Erlang's :logger removes any handler filter that returns an unexpected
# value or raises. Valid returns are `:stop` (drop), `:ignore` (defer to
# other filters), or the `log_event` map itself (let it through). The
# previous version returned `:log`, which OTP 27+ treats as invalid and
# evicts the filter — losing all noise suppression.
defmodule Cympho.Test.LoggerFilter do
  def sandbox_disconnect(log_event, _arg) do
    try do
      case render(log_event) do
        text when is_binary(text) ->
          if String.contains?(text, "disconnected") and
               String.contains?(text, "DBConnection.ConnectionError") do
            :stop
          else
            log_event
          end

        _ ->
          log_event
      end
    catch
      _, _ -> log_event
    end
  end

  defp render(%{msg: {:string, msg}}), do: safe_to_binary(msg)
  defp render(%{msg: msg}) when is_binary(msg), do: msg

  defp render(%{msg: {format, args}}) when is_list(args) do
    safe_to_binary(:io_lib.format(format, args))
  end

  defp render(%{msg: {:report, _report}}), do: nil
  defp render(_), do: nil

  defp safe_to_binary(value) when is_binary(value), do: value
  defp safe_to_binary(value), do: IO.iodata_to_binary(value)
end

try do
  :logger.add_handler_filter(
    :default,
    :sandbox_disconnect_filter,
    {&Cympho.Test.LoggerFilter.sandbox_disconnect/2, nil}
  )
rescue
  _ -> :ok
end
