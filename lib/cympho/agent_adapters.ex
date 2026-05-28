defmodule Cympho.AgentAdapters do
  @moduledoc """
  Deprecated. Call `Cympho.Adapters` directly. This module will be removed
  in a follow-up release once all internal callers have migrated.

  Each delegating function emits a `Logger.warning` with
  `component: :agent_adapters_shim` so that any forgotten downstream caller
  surfaces in logs rather than crashing.
  """

  require Logger

  def register(type, module) do
    warn_deprecated(:register)
    Cympho.Adapters.register(type, module)
  end

  def resolve(agent) do
    warn_deprecated(:resolve)
    Cympho.Adapters.resolve(agent)
  end

  def fallback_chain(primary) do
    warn_deprecated(:fallback_chain)
    Cympho.Adapters.fallback_chain(primary)
  end

  def all_types do
    warn_deprecated(:all_types)
    Cympho.Adapters.all_types()
  end

  def lookup(type) do
    warn_deprecated(:lookup)
    Cympho.Adapters.lookup(type)
  end

  defp warn_deprecated(fun) do
    Logger.warning(
      "Cympho.AgentAdapters.#{fun} is deprecated; call Cympho.Adapters.#{fun} directly",
      component: :agent_adapters_shim
    )
  end
end
