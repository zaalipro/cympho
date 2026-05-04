defmodule CymphoWeb.Toast do
  @moduledoc """
  Helper for sending toast notifications from LiveViews and Plug controllers.

  Toasts render in the top-right via the `Toast` JS hook on
  `#toast-container` (mounted on the root layout). Use this helper instead
  of `put_flash/3` for transient feedback ("Saved.", "Failed: …") since
  flashes don't auto-dismiss and don't queue.

  Examples:

      socket |> Toast.success("Saved.") |> noreply()
      socket |> Toast.error("Could not save: \#{reason}")
      Toast.send(socket, :info, "Working on it…", key: "agent-spawn")

  The `key` option dedups: repeated toasts with the same key inside a 3s
  window are dropped (configured client-side in the hook).
  """

  alias Phoenix.LiveView

  @type type :: :info | :success | :error | :warning

  @spec info(LiveView.Socket.t(), String.t(), Keyword.t()) :: LiveView.Socket.t()
  def info(socket, message, opts \\ []), do: send(socket, :info, message, opts)

  @spec success(LiveView.Socket.t(), String.t(), Keyword.t()) :: LiveView.Socket.t()
  def success(socket, message, opts \\ []), do: send(socket, :success, message, opts)

  @spec error(LiveView.Socket.t(), String.t(), Keyword.t()) :: LiveView.Socket.t()
  def error(socket, message, opts \\ []), do: send(socket, :error, message, opts)

  @spec warning(LiveView.Socket.t(), String.t(), Keyword.t()) :: LiveView.Socket.t()
  def warning(socket, message, opts \\ []), do: send(socket, :warning, message, opts)

  @spec send(LiveView.Socket.t(), type(), String.t(), Keyword.t()) :: LiveView.Socket.t()
  def send(socket, type, message, opts \\ [])
      when type in [:info, :success, :error, :warning] do
    payload =
      %{type: Atom.to_string(type), message: message}
      |> maybe_put(:key, Keyword.get(opts, :key))

    LiveView.push_event(socket, "toast", payload)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
