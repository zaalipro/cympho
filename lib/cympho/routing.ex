defmodule Cympho.Routing do
  @moduledoc """
  Layered router that picks an issue's `assigned_role`.

  The default path is:

    1. If the issue already has a non-blank `assigned_role`, keep it.
    2. Otherwise, try the LLM classifier (`Cympho.Routing.LlmClassifier`).
    3. If the classifier is disabled, missing a key, errors, or returns
       junk, fall back to the deterministic keyword router
       (`Cympho.Orchestrator.Dispatcher.Router.infer_role/1`).

  Persisting the result also records provenance in
  `monitor_state["routing"]` so re-classification on edit can avoid
  clobbering manually-pinned roles.

  All paths emit a `[:cympho, :routing, :classified]` telemetry event so
  operators can watch the seam in production.
  """

  alias Cympho.Issues
  alias Cympho.Issues.Issue
  alias Cympho.Orchestrator.Dispatcher.Router
  alias Cympho.Routing.LlmClassifier

  require Logger

  @type source :: :llm | :keyword | :fallback

  @doc """
  Returns `{:ok, role, source}` where `source` describes how the role was
  derived. Never raises — falls back to the keyword router on any error.
  """
  @spec classify_role(map(), keyword()) :: {:ok, atom(), source()}
  def classify_role(issue, opts \\ []) when is_map(issue) do
    start = System.monotonic_time()

    {role, source} =
      cond do
        not Application.get_env(:cympho, :llm_router_enabled?, true) ->
          {Router.infer_role(issue), :fallback}

        not LlmClassifier.configured?() ->
          {Router.infer_role(issue), :fallback}

        true ->
          case safe_classify(issue, opts) do
            {:ok, role} ->
              {role, :llm}

            {:error, _reason} ->
              {Router.infer_role(issue), :fallback}
          end
      end

    emit_telemetry(issue, role, source, start)
    {:ok, role, source}
  end

  @doc """
  Classifies the issue. When the LLM produced a real role, persist it on
  the row along with `monitor_state["routing"]` provenance. For fallback
  paths we keep the row untouched so the keyword router can still resolve
  the role at dispatch time — this matches today's deterministic
  behaviour and avoids racing with tests that assume `assigned_role` stays
  blank.

  Safe to call from a `Task.Supervisor` child — never raises.
  """
  @spec classify_and_persist(Issue.t(), keyword()) ::
          {:ok, Issue.t()} | {:noop, Issue.t()} | {:error, term()}
  def classify_and_persist(%Issue{} = issue, opts \\ []) do
    {:ok, role, source} = classify_role(issue, opts)

    case source do
      :llm ->
        persist_llm_role(issue, role)

      _ ->
        {:noop, issue}
    end
  rescue
    e ->
      Logger.warning("[Routing] classify_and_persist crash: #{Exception.message(e)}")
      {:error, e}
  end

  defp persist_llm_role(%Issue{} = issue, role) do
    routing_meta = %{
      "source" => "llm",
      "classified_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "model" => LlmClassifier.model()
    }

    monitor_state =
      issue.monitor_state
      |> normalize_monitor_state()
      |> Map.put("routing", routing_meta)

    attrs = %{
      assigned_role: Atom.to_string(role),
      monitor_state: monitor_state
    }

    case Issues.update_issue(issue, attrs) do
      {:ok, updated} ->
        {:ok, updated}

      {:error, reason} ->
        Logger.warning(
          "[Routing] failed to persist classified role issue=#{issue.id} " <>
            "reason=#{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  @doc """
  Decides whether an issue needs classification. True when:

    * It has no `assigned_role`, OR
    * `monitor_state["routing"]["source"] == "llm"` (re-classify on edit
      only if the prior label was LLM-driven).
  """
  @spec should_classify?(Issue.t()) :: boolean()
  def should_classify?(%Issue{} = issue) do
    blank_role?(issue.assigned_role) or llm_sourced?(issue)
  end

  defp llm_sourced?(%Issue{monitor_state: %{"routing" => %{"source" => "llm"}}}), do: true
  defp llm_sourced?(_), do: false

  defp blank_role?(nil), do: true
  defp blank_role?(""), do: true
  defp blank_role?(_), do: false

  defp safe_classify(issue, opts) do
    timeout =
      opts[:timeout_ms] ||
        Application.get_env(:cympho, :llm_classifier_timeout_ms, 1_500)

    # `Task.async`/`yield` keeps the call cancellable with a hard timeout
    # bound — the classifier itself also passes the timeout to Finch, but
    # this protects against a hang anywhere up the chain.
    task = Task.async(fn -> LlmClassifier.classify(issue, opts) end)

    case Task.yield(task, timeout + 200) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :timeout}
    end
  rescue
    e -> {:error, e}
  catch
    :exit, reason -> {:error, reason}
  end

  defp normalize_monitor_state(%{} = ms), do: ms
  defp normalize_monitor_state(_), do: %{}

  defp emit_telemetry(issue, role, source, start) do
    duration_ms =
      System.convert_time_unit(System.monotonic_time() - start, :native, :millisecond)

    :telemetry.execute(
      [:cympho, :routing, :classified],
      %{duration_ms: duration_ms, source: source},
      %{issue_id: Map.get(issue, :id), classified_role: role}
    )
  end
end
