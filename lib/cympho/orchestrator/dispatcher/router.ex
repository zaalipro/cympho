defmodule Cympho.Orchestrator.Dispatcher.Router do
  @moduledoc """
  Keyword-driven routing engine for issue auto-assignment.

  Classifies issues by role based on title/description keywords,
  selects the least-loaded eligible agent, and provides fallback chains.
  """

  @strategic_keywords ~w[strategic vision roadmap funding market partnership acquisition ceo]
  @technical_keywords ~w[technical architecture plan review refactor system infrastructure cto]
  @implementation_keywords ~w[implement build fix test code feature bug integration deploy]

  @doc """
  Infers the appropriate role for an issue based on keywords in title and description.

  Returns `:ceo`, `:cto`, or `:engineer`.
  """
  @spec infer_role(map()) :: :ceo | :cto | :engineer
  def infer_role(issue) do
    case assigned_role(issue) do
      role when role in [:ceo, :cto, :engineer] ->
        role

      _ ->
        infer_role_from_text(issue)
    end
  end

  defp infer_role_from_text(issue) do
    text = "#{field(issue, :title)} #{field(issue, :description) || ""}" |> String.downcase()

    cond do
      matches_any?(text, @strategic_keywords) -> :ceo
      matches_any?(text, @technical_keywords) -> :cto
      matches_any?(text, @implementation_keywords) -> :engineer
      true -> :engineer
    end
  end

  defp assigned_role(issue) do
    case field(issue, :assigned_role) do
      role when is_atom(role) -> role
      role when is_binary(role) -> role_to_atom(role)
      _ -> nil
    end
  end

  defp role_to_atom("ceo"), do: :ceo
  defp role_to_atom("cto"), do: :cto
  defp role_to_atom("engineer"), do: :engineer
  defp role_to_atom(_), do: nil

  defp field(%{} = map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp field(_issue, _key), do: nil

  @doc """
  Selects the least-loaded eligible agent for the given role.
  Tie-breaks by round-robin using agent name.

  Returns {:ok, agent} or {:error, :no_agent_available}.
  """
  @spec select_agent(:ceo | :cto | :engineer, [Cympho.Agents.Agent.t()]) ::
          {:ok, Cympho.Agents.Agent.t()} | {:error, :no_agent_available}
  def select_agent(role, eligible_agents) do
    eligible_agents
    |> Enum.filter(fn agent -> agent.role == role and agent.status != :error end)
    |> Enum.sort_by(fn agent -> {agent_count_load(agent), agent.name} end)
    |> List.first()
    |> case do
      nil -> {:error, :no_agent_available}
      agent -> {:ok, agent}
    end
  end

  @doc """
  Returns the ordered fallback chain for a role.

  - `:ceo` → [] (strategic queues for CEO only)
  - `:cto` → [:ceo]
  - `:engineer` → [:cto, :ceo]
  """
  @spec fallback_chain(:ceo | :cto | :engineer) :: [:cto | :ceo, ...]
  def fallback_chain(:ceo), do: []
  def fallback_chain(:cto), do: [:ceo]
  def fallback_chain(:engineer), do: [:cto, :ceo]

  defp matches_any?(text, keywords) do
    Enum.any?(keywords, &String.contains?(text, &1))
  end

  defp agent_count_load(agent) do
    Cympho.Agents.count_active_assignments(agent.id)
  end
end
