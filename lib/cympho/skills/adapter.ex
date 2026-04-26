defmodule Cympho.Skills.Adapter do
  @moduledoc """
  Behavior for skill adapters that format skill metadata for LLM prompts.
  """

  @callback skill_prompt_fragment(skill :: map()) :: String.t()
  @callback supported_capabilities() :: list(String.t())

  def skill_prompt_fragment(:claude_local, skill) do
    name = Map.get(skill, :name, "Unknown")
    version = Map.get(skill, :version, "0.0.0")
    capabilities = Map.get(skill, :capabilities, [])
    identifier = Map.get(skill, :identifier, name)
    caps = Enum.join(capabilities, ", ")

    """
    ### Skill: #{name} (#{version})
    Identifier: `#{identifier}`
    Capabilities: #{caps || "none"}
    """
    |> String.trim()
    |> Kernel.<>("\n")
  end

  def skill_prompt_fragment(_adapter, _skill), do: ""

  def supported_capabilities(:claude_local) do
    ["file_io", "web_search", "code_exec", "database", "api_call", "web_browse", "git"]
  end

  def supported_capabilities(_adapter), do: []
end
