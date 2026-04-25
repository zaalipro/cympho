defmodule Cympho.Plugins.Worker do
  @moduledoc """
  Worker behavior for plugin processes.
  """
  use GenServer

  defmacro __using__(_opts) do
    quote do
      use GenServer
      @behaviour Cympho.Plugins.Worker

      @impl true
      def init(args) do
        plugin = Keyword.fetch!(args, :plugin)
        company_id = Keyword.fetch!(args, :company_id)

        state = %{
          plugin: plugin,
          company_id: company_id,
          status: :initialized
        }

        case handle_init(state) do
          {:ok, state} -> {:ok, state}
          {:stop, reason} -> {:stop, reason}
        end
      end

      @impl true
      def handle_info(message, state) do
        handle_message(message, state)
      end

      @impl true
      def handle_call(request, from, state) do
        handle_request(request, from, state)
      end

      @impl true
      def handle_cast(request, state) do
        handle_cast_request(request, state)
      end

      @impl true
      def terminate(reason, state) do
        handle_terminate(reason, state)
      end

      def handle_init(state), do: {:ok, state}
      def handle_message(message, state), do: {:noreply, state}
      def handle_request(request, from, state), do: {:reply, :ok, state}
      def handle_cast_request(request, state), do: {:noreply, state}
      def handle_terminate(_reason, _state), do: :ok

      defoverridable handle_init: 1,
                     handle_message: 2,
                     handle_request: 3,
                     handle_cast_request: 2,
                     handle_terminate: 2
    end
  end

  @callback init(keyword()) :: {:ok, map()} | {:stop, term()}
  @callback handle_message(term(), map()) :: {:noreply, map()} | {:stop, term(), map()}
  @callback handle_request(term(), term(), map()) :: {:reply, term(), map()} | {:noreply, map()}
  @callback handle_cast_request(term(), map()) :: {:noreply, map()}
  @callback handle_terminate(term(), map()) :: term()
end
