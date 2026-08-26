defmodule Cympho.Companies.ImportDecodeAdmission do
  @moduledoc """
  Node-local admission for company-import operations that retain a decoded V1 map.

  V1 import packages are decoded as one map. Allowing previews and applies to
  decode concurrently can multiply their peak memory use, so this process grants
  one fail-fast slot per BEAM node. The holder is monitored and its slot is
  reclaimed if the request process exits before releasing it.

  Raw part uploads do not use this admission path.
  """

  use GenServer

  @type token :: reference()

  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, :ok)
      name -> GenServer.start_link(__MODULE__, :ok, name: name)
    end
  end

  @doc "Attempts to reserve the node's single decoded-import slot without waiting."
  @spec checkout(GenServer.server()) :: {:ok, token()} | {:error, :busy}
  def checkout(server \\ __MODULE__) do
    GenServer.call(server, :checkout)
  catch
    :exit, _reason -> {:error, :busy}
  end

  @doc "Releases a slot held by the calling process."
  @spec release(token(), GenServer.server()) :: :ok
  def release(token, server \\ __MODULE__) do
    GenServer.call(server, {:release, token})
  catch
    :exit, _reason -> :ok
  end

  @impl true
  def init(:ok), do: {:ok, nil}

  @impl true
  def handle_call(:checkout, {pid, _tag}, nil) do
    monitor = Process.monitor(pid)
    token = make_ref()
    {:reply, {:ok, token}, {pid, monitor, token}}
  end

  def handle_call(:checkout, _from, holder), do: {:reply, {:error, :busy}, holder}

  def handle_call({:release, token}, {pid, _tag}, {pid, monitor, token}) do
    Process.demonitor(monitor, [:flush])
    {:reply, :ok, nil}
  end

  def handle_call({:release, _token}, _from, holder), do: {:reply, :ok, holder}

  @impl true
  def handle_info({:DOWN, monitor, :process, pid, _reason}, {pid, monitor, _token}),
    do: {:noreply, nil}

  def handle_info(_message, holder), do: {:noreply, holder}
end
