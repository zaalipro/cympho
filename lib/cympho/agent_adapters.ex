defmodule Cympho.AgentAdapters do
  @moduledoc """
  Backwards-compatible shim. Delegates to `Cympho.Adapters`, which is the
  canonical home for adapter discovery, registration, and resolution.

  New code should call `Cympho.Adapters` directly.
  """

  defdelegate register(type, module), to: Cympho.Adapters
  defdelegate resolve(agent), to: Cympho.Adapters
  defdelegate fallback_chain(primary), to: Cympho.Adapters
  defdelegate all_types(), to: Cympho.Adapters
  defdelegate lookup(type), to: Cympho.Adapters
end
