defmodule Cympho.Adapters.MockAdapter do
  @moduledoc """
  Test-only adapter that pulls scripted `cympho-actions` payloads from an
  ETS table instead of calling out to a CLI or HTTP backend.

  Scripts are keyed by `{agent_id, issue_id}` and consumed in FIFO order;
  each script entry can be one of:

    * `%{result: result}` — sent as `{:turn_completed, session_id, result}`
    * `%{error: reason}` — sent as `{:turn_ended_with_error, session_id, reason}`
    * `:silent` — sends `:session_started` but no further messages (used
      by the stuck-engineer test). Stays in the script slot until cleared.

  Use `script/3` to push entries onto a key, `clear/0` to wipe everything,
  and `clear/2` for a specific pair. The adapter raises in `register_builtin/0`
  if `Mix.env() != :test` so a release build cannot accidentally use it.
  """

  @behaviour Cympho.Adapters.Adapter

  @table :cympho_mock_adapter_scripts

  ## Public API

  @doc """
  Pushes script entries onto the FIFO queue for an `{agent_id, issue_id}`
  pair. Existing entries are appended to (not replaced).
  """
  @spec script(binary(), binary(), [map() | :silent]) :: :ok
  def script(agent_id, issue_id, entries) when is_list(entries) do
    ensure_table()
    key = key(agent_id, issue_id)
    existing = lookup_queue(key)
    :ets.insert(@table, {key, existing ++ entries})
    :ok
  end

  @doc "Removes every scripted entry."
  @spec clear() :: :ok
  def clear do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  @doc "Removes scripted entries for a specific `{agent_id, issue_id}` pair."
  @spec clear(binary(), binary()) :: :ok
  def clear(agent_id, issue_id) do
    ensure_table()
    :ets.delete(@table, key(agent_id, issue_id))
    :ok
  end

  ## Adapter behaviour

  @impl true
  def run(issue, agent_id, recipient_pid, opts \\ []) when is_pid(recipient_pid) do
    session_id = make_ref()
    ensure_table()
    key = key(agent_id, issue_id(issue))

    spawn(fn ->
      send(recipient_pid, {:session_started, session_id})
      delay = Keyword.get(opts, :mock_delay, 5)
      if delay > 0, do: Process.sleep(delay)

      case pop(key) do
        :silent ->
          # `:silent` sticks — re-insert so subsequent runs also stall.
          :ets.insert(@table, {key, [:silent | lookup_queue(key)]})
          :ok

        {:ok, %{result: result}} ->
          send(recipient_pid, {:turn_completed, session_id, result})
          send(recipient_pid, {:session_ended, session_id, :normal})

        {:ok, %{error: reason}} ->
          send(recipient_pid, {:turn_ended_with_error, session_id, reason})

        :empty ->
          send(
            recipient_pid,
            {:turn_ended_with_error, session_id,
             {:no_script_entry, %{agent_id: agent_id, issue_id: issue_id(issue)}}}
          )
      end
    end)

    session_id
  end

  @impl true
  def health_check(_config) do
    %{
      status: :healthy,
      message: "Mock adapter (test-only)",
      checked_at: DateTime.utc_now()
    }
  end

  @impl true
  def config_schema, do: []

  @impl true
  def name, do: "Mock"

  @impl true
  def available?, do: Mix.env() == :test

  @impl true
  def available?(_config), do: available?()

  @impl true
  def type, do: :mock

  @impl true
  def validate_config(_config), do: :ok

  ## Internals

  defp ensure_table do
    if :ets.info(@table) == :undefined do
      :ets.new(@table, [:named_table, :set, :public])
    end
  end

  defp pop(key) do
    case :ets.lookup(@table, key) do
      [{^key, [:silent | _] = queue}] ->
        # Don't drain :silent; keep it as a sticky stall.
        _ = :ets.insert(@table, {key, queue})
        :silent

      [{^key, [first | rest]}] ->
        :ets.insert(@table, {key, rest})
        {:ok, first}

      [{^key, []}] ->
        :empty

      [] ->
        :empty
    end
  end

  defp lookup_queue(key) do
    case :ets.lookup(@table, key) do
      [{^key, queue}] when is_list(queue) -> queue
      _ -> []
    end
  end

  defp key(agent_id, issue_id), do: {to_string(agent_id), to_string(issue_id)}

  defp issue_id(%{id: id}), do: id
  defp issue_id(id) when is_binary(id), do: id
  defp issue_id(_), do: nil
end
