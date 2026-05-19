defmodule Cympho.Orchestrator.Dispatcher.Router do
  @moduledoc """
  Keyword-driven routing engine for issue auto-assignment.

  Classifies issues by role based on title/description keywords,
  selects the least-loaded eligible agent, and provides fallback chains.
  """

  @strategic_keywords ~w[strategic vision funding market partnership acquisition ceo]
  @product_keywords ~w[product roadmap customer acceptance requirements priority prioritization pm]
  @design_keywords ~w[ux ui interface workflow prototype usability research]
  @technical_keywords ~w[technical architecture plan review refactor system infrastructure cto]
  @implementation_keywords ~w[implement build fix test code feature bug integration]
  # Release-engineering work: branch coordination, merge mechanics, deploys,
  # tagging. Keep this BEFORE @implementation_keywords so a "deploy the auth
  # service" issue lands with the release engineer rather than a generic
  # engineer. "deploy" was previously in @implementation_keywords; it now
  # routes to release_engineer.
  @release_keywords ~w[merge rebase release deploy ship version tag changelog hotfix conflict]

  @doc """
  Infers the appropriate role for an issue based on keywords in title and description.

  Returns `:ceo`, `:cto`, `:product_manager`, `:designer`, `:engineer`, or `:release_engineer`.
  """
  @spec infer_role(map()) ::
          :ceo | :cto | :product_manager | :designer | :engineer | :release_engineer
  def infer_role(issue) do
    case assigned_role(issue) do
      role
      when role in [:ceo, :cto, :product_manager, :designer, :engineer, :release_engineer] ->
        role

      _ ->
        infer_role_from_text(issue)
    end
  end

  defp infer_role_from_text(issue) do
    text = "#{field(issue, :title)} #{field(issue, :description) || ""}" |> String.downcase()

    # Matching order is routing priority. Strategic owner work stays with the
    # CEO; technical platform words beat product/design words when both appear.
    # Release keywords are checked before implementation keywords so explicit
    # merge/deploy work doesn't fall to a generic engineer.
    cond do
      matches_any?(text, @strategic_keywords) -> :ceo
      matches_any?(text, @technical_keywords) -> :cto
      matches_any?(text, @product_keywords) -> :product_manager
      matches_any?(text, @design_keywords) -> :designer
      matches_any?(text, @release_keywords) -> :release_engineer
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
  defp role_to_atom("product_manager"), do: :product_manager
  defp role_to_atom("designer"), do: :designer
  defp role_to_atom("engineer"), do: :engineer
  defp role_to_atom("release_engineer"), do: :release_engineer
  defp role_to_atom(_), do: nil

  defp field(%{} = map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp field(_issue, _key), do: nil

  @doc """
  Selects the least-loaded eligible agent for the given role.
  Tie-breaks by round-robin using agent name.

  Returns {:ok, agent} or {:error, :no_agent_available}.
  """
  @spec select_agent(:ceo | :cto | :product_manager | :designer | :engineer, [
          Cympho.Agents.Agent.t()
        ]) ::
          {:ok, Cympho.Agents.Agent.t()} | {:error, :no_agent_available}
  def select_agent(role, eligible_agents) do
    eligible_agents
    |> Enum.filter(fn agent -> agent.role == role and agent.status != :error end)
    |> Enum.sort_by(fn agent ->
      # Weighted load: prefer the agent with the smallest sum of
      # `estimated_minutes` across in-flight issues; fall back to raw
      # count and name for stable ordering. Issues without an estimate
      # contribute the configured default (60 min) so they aren't free.
      {agent_estimated_load(agent), agent_count_load(agent), agent.name}
    end)
    |> List.first()
    |> case do
      nil -> {:error, :no_agent_available}
      agent -> {:ok, agent}
    end
  end

  @doc """
  Returns the ordered fallback chain for a role.

  - `:ceo` → [] (strategic queues for CEO only)
  - `:product_manager` → [:ceo]
  - `:designer` → [:product_manager, :ceo]
  - `:cto` → [:ceo]
  - `:engineer` → [:cto, :ceo]
  """
  @spec fallback_chain(
          :ceo | :cto | :product_manager | :designer | :engineer | :release_engineer
        ) :: [
          :product_manager | :cto | :ceo | :engineer,
          ...
        ]
  def fallback_chain(:ceo), do: []
  def fallback_chain(:product_manager), do: [:ceo]
  def fallback_chain(:designer), do: [:product_manager, :ceo]
  def fallback_chain(:cto), do: [:ceo]
  def fallback_chain(:engineer), do: [:cto, :ceo]
  # Release engineers fall back to a generic engineer (any engineer can do
  # the work in a pinch), then up the chain. CTO is the ultimate ownership
  # tier for technical work.
  def fallback_chain(:release_engineer), do: [:engineer, :cto, :ceo]

  defp matches_any?(text, keywords) do
    Enum.any?(keywords, fn keyword ->
      Regex.match?(~r/(^|[^a-z0-9])#{Regex.escape(keyword)}([^a-z0-9]|$)/, text)
    end)
  end

  defp agent_count_load(agent) do
    Cympho.Agents.count_active_assignments(agent.id)
  end

  @default_estimate_minutes 60

  # Sum of `monitor_state["estimated_minutes"]` across this agent's in-flight
  # issues. Issues with no estimate contribute the default, so a brand-new
  # issue can't slip in for free.
  defp agent_estimated_load(agent) do
    import Ecto.Query, warn: false
    alias Cympho.Issues.Issue

    estimates =
      Cympho.Repo.all(
        from i in Issue,
          where:
            i.assignee_id == ^agent.id and
              i.status in ^[:todo, :in_progress, :in_review, :blocked],
          select: i.monitor_state
      )

    Enum.reduce(estimates, 0, fn ms, acc ->
      acc + estimate_minutes(ms)
    end)
  end

  defp estimate_minutes(%{"estimated_minutes" => n}) when is_integer(n) and n > 0, do: n
  defp estimate_minutes(_), do: @default_estimate_minutes
end
