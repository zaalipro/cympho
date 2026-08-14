defmodule Cympho.Adapters.RunDeadline do
  @moduledoc """
  Tracks both the stall and the absolute wall-clock deadline of an adapter run.

  Adapter receive loops are written as `receive ... after stall_timeout`, and
  that timer restarts on every message. A CLI that prints something every few
  seconds — `codex exec --json` emits an event line per step — therefore never
  trips it. Nothing downstream bounds such a run either: the orchestrator stamps
  a run heartbeat every 30s, which hides it from the watchdog's stale-run scan;
  the adapter session stays registered, which satisfies the liveness check; and
  provider usage is only recorded when a run finishes, so a budget hard stop can
  never fire. The run pins its dispatch slot and bills indefinitely.

  This struct carries both deadlines so a loop can wait for whichever comes
  first and then say which budget was exhausted.

  `Cympho.AgentRunner` already had its own `max_run_ms`; this is the same idea
  for the adapters that talk to a port directly.
  """

  @enforce_keys [:stall_timeout, :max_run_ms, :started_at, :last_output_at]
  defstruct [:stall_timeout, :max_run_ms, :started_at, :last_output_at]

  @type t :: %__MODULE__{
          stall_timeout: pos_integer(),
          max_run_ms: pos_integer(),
          started_at: integer(),
          last_output_at: integer()
        }

  @default_max_run_ms 3_600_000

  @doc """
  The absolute cap applied when a caller does not pass one.

  Read at runtime from `config :cympho, :adapter_max_run_ms` so an operator can
  tighten it without a recompile.
  """
  @spec default_max_run_ms() :: pos_integer()
  def default_max_run_ms do
    Application.get_env(:cympho, :adapter_max_run_ms, @default_max_run_ms)
  end

  @doc """
  Starts tracking.

  The absolute cap wins even when it is shorter than the configured stall
  timeout: a stall timeout longer than the cap is a misconfiguration, and the
  safe reading of an absolute bound is that nothing outlives it.
  """
  @spec new(pos_integer(), pos_integer() | nil) :: t()
  def new(stall_timeout, max_run_ms \\ nil)

  def new(stall_timeout, nil), do: new(stall_timeout, default_max_run_ms())

  def new(stall_timeout, max_run_ms) do
    now = System.monotonic_time(:millisecond)

    %__MODULE__{
      stall_timeout: stall_timeout,
      max_run_ms: max_run_ms,
      started_at: now,
      last_output_at: now
    }
  end

  @doc """
  Records that output just arrived, resetting only the stall deadline.
  """
  @spec touch(t()) :: t()
  def touch(%__MODULE__{} = deadline) do
    %{deadline | last_output_at: System.monotonic_time(:millisecond)}
  end

  @doc """
  Milliseconds until the nearest deadline. Zero means one has passed, and the
  caller should ask `expired/1` which.
  """
  @spec wait_ms(t()) :: non_neg_integer()
  def wait_ms(%__MODULE__{} = deadline) do
    now = System.monotonic_time(:millisecond)
    remaining_max = max(deadline.started_at + deadline.max_run_ms - now, 0)
    remaining_stall = max(deadline.last_output_at + deadline.stall_timeout - now, 0)
    min(remaining_max, remaining_stall)
  end

  @doc """
  Which budget is exhausted, or `nil` when the timer fired on a clock-resolution
  edge and the loop should simply re-enter.
  """
  @spec expired(t()) :: :max_run | :stall | nil
  def expired(%__MODULE__{} = deadline) do
    now = System.monotonic_time(:millisecond)

    cond do
      now - deadline.started_at >= deadline.max_run_ms -> :max_run
      now - deadline.last_output_at >= deadline.stall_timeout -> :stall
      true -> nil
    end
  end
end
