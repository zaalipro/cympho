defmodule Cympho.Readiness.Cache do
  @moduledoc false

  use GenServer

  alias Cympho.Readiness

  @cache_ttl_ms 1_000
  @max_cache_ttl_ms 5_000
  @call_grace_ms 250
  @probe_grace_ms 50
  @max_waiters 64

  defstruct report: nil,
            opts: nil,
            expires_at: 0,
            task: nil,
            timer: nil,
            waiters: []

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc "Returns a cached readiness report or joins the node's single in-flight probe."
  def report(opts \\ []) do
    if Readiness.valid_options?(opts) do
      timeout = Readiness.timeout_ms(opts) + @call_grace_ms
      GenServer.call(__MODULE__, {:report, opts}, timeout)
    else
      Readiness.unavailable_report()
    end
  rescue
    _error -> Readiness.unavailable_report()
  catch
    :exit, _reason -> Readiness.unavailable_report()
  end

  @doc false
  def invalidate do
    GenServer.call(__MODULE__, :invalidate)
  catch
    :exit, _reason -> :ok
  end

  @impl true
  def init(_opts), do: {:ok, %__MODULE__{}}

  @impl true
  def handle_call({:report, opts}, from, state) do
    now = System.monotonic_time(:millisecond)

    cond do
      fresh?(state, opts, now) ->
        {:reply, state.report, state}

      state.task && state.opts == opts && length(state.waiters) < @max_waiters ->
        {:noreply, %{state | waiters: [from | state.waiters]}}

      state.task ->
        {:reply, Readiness.unavailable_report(), state}

      true ->
        start_refresh(from, opts, state)
    end
  end

  def handle_call(:invalidate, _from, state) do
    state = stop_refresh(state)
    reply_waiters(state.waiters, Readiness.unavailable_report())
    {:reply, :ok, %__MODULE__{}}
  end

  @impl true
  def handle_info({ref, report}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    cancel_timer(state.timer)
    {:noreply, finish_refresh(state, report)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{task: %Task{ref: ref}} = state) do
    cancel_timer(state.timer)
    {:noreply, finish_refresh(state, Readiness.unavailable_report())}
  end

  def handle_info({:probe_timeout, ref}, %{task: %Task{ref: ref} = task} = state) do
    _ = Task.shutdown(task, :brutal_kill)
    {:noreply, finish_refresh(state, Readiness.unavailable_report())}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp start_refresh(from, opts, state) do
    task =
      Task.Supervisor.async_nolink(Cympho.TaskSupervisor, fn ->
        Readiness.report(opts)
      end)

    timer =
      Process.send_after(
        self(),
        {:probe_timeout, task.ref},
        Readiness.timeout_ms(opts) + @probe_grace_ms
      )

    {:noreply,
     %{
       state
       | report: nil,
         opts: opts,
         expires_at: 0,
         task: task,
         timer: timer,
         waiters: [from]
     }}
  rescue
    _error -> {:reply, Readiness.unavailable_report(), state}
  catch
    :exit, _reason -> {:reply, Readiness.unavailable_report(), state}
  end

  defp finish_refresh(state, report) do
    report = valid_report(report)
    reply_waiters(state.waiters, report)
    now = System.monotonic_time(:millisecond)

    %{
      state
      | report: report,
        expires_at: now + cache_ttl_ms(state.opts),
        task: nil,
        timer: nil,
        waiters: []
    }
  end

  defp valid_report(
         %{
           schema_version: 1,
           status: status,
           service: "cympho",
           release: %{version: version, revision: revision},
           checks: %{
             application: application,
             database: database,
             migrations: migrations
           }
         } = report
       )
       when status in ["ready", "not_ready"] and is_binary(version) and is_binary(revision) and
              application in ["ready", "unavailable"] and
              database in ["ready", "unavailable", "timeout"] and
              migrations in ["ready", "pending", "unavailable", "timeout"],
       do: report

  defp valid_report(_report), do: Readiness.unavailable_report()

  defp fresh?(state, opts, now) do
    not is_nil(state.report) and state.opts == opts and now < state.expires_at
  end

  defp cache_ttl_ms(opts) do
    case option(opts, :cache_ttl_ms) do
      value when is_integer(value) and value > 0 and value <= @max_cache_ttl_ms -> value
      _other -> @cache_ttl_ms
    end
  end

  defp option(opts, key) when is_list(opts), do: Keyword.get(opts, key)
  defp option(opts, key) when is_map(opts), do: Map.get(opts, key)
  defp option(_opts, _key), do: nil

  defp reply_waiters(waiters, report) do
    Enum.each(waiters, &GenServer.reply(&1, report))
  end

  defp stop_refresh(%{task: %Task{} = task} = state) do
    cancel_timer(state.timer)
    _ = Task.shutdown(task, :brutal_kill)
    %{state | task: nil, timer: nil}
  end

  defp stop_refresh(state), do: state

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer)
end
