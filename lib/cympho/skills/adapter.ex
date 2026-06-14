defmodule Cympho.Skills.Adapter do
  @moduledoc """
  Behavior for skill adapters that format skill metadata for LLM prompts.
  """

  @callback skill_prompt_fragment(skill :: map()) :: String.t()
  @callback supported_capabilities() :: list(String.t())

  def skill_prompt_fragment(:claude_local, skill) do
    name = field(skill, :name, "name", "Unknown")
    version = field(skill, :version, "version", "0.0.0")
    capabilities = field(skill, :capabilities, "capabilities", []) || []
    identifier = field(skill, :identifier, "identifier", name)
    description = field(skill, :description, "description", nil)
    entrypoint = field(skill, :entrypoint, "entrypoint", nil)
    caps = if Enum.empty?(capabilities), do: "none", else: Enum.join(capabilities, ", ")

    """
    ### Skill: #{name} (#{version})
    Identifier: `#{identifier}`
    Capabilities: #{caps || "none"}
    #{optional_line("Description", description)}
    #{optional_line("Entrypoint", entrypoint)}
    """
    |> String.trim()
    |> Kernel.<>("\n")
  end

  def skill_prompt_fragment(_adapter, _skill), do: ""

  def supported_capabilities(:claude_local) do
    ["file_io", "web_search", "code_exec", "database", "api_call", "web_browse", "git"]
  end

  def supported_capabilities(_adapter), do: []

  defp field(skill, atom_key, string_key, default) when is_map(skill) do
    Map.get(skill, atom_key) || Map.get(skill, string_key) || default
  end

  defp optional_line(_label, value) when value in [nil, ""], do: nil
  defp optional_line(label, value), do: "#{label}: #{value}"
end
