defmodule Cympho.Evaluations do
  @moduledoc """
  Company-scoped durable evaluation suites, immutable runs/results, feedback,
  deterministic reruns, and run comparisons.

  Fail-closed multi-tenancy: every write requires `company_id`. Cross-tenant
  getters return `{:error, :not_found}`. Provenance hashes are redacted and
  immutable after insert.
  """

  import Ecto.Query, warn: false

  alias Cympho.AgentPromptContractEval
  alias Cympho.Repo

  alias Cympho.Evaluations.{
    EvaluationFeedback,
    EvaluationResult,
    EvaluationRun,
    EvaluationSuite
  }

  @redacted_placeholder "[REDACTED]"

  @secret_fields MapSet.new(~w(
    password_hash key_hash encrypted_value webhook_secret github_webhook_secret
    api_key password secret token access_token refresh_token auth_token
    authorization cookie database_url credential credentials headers env auth
    authentication secrets private_key client_secret
  ))

  # Intentionally omit bare "_key" — it false-positives on case_key/suite_key.
  @secret_field_suffixes ~w(
    _api_key _password _secret _token _authorization _cookie _database_url
    _credential _credentials _private_key
  )

  # ── Suites ──────────────────────────────────────────────────────────────

  @doc """
  Creates a company-scoped evaluation suite. Requires `:company_id`.
  """
  def create_suite(attrs) when is_map(attrs) do
    attrs = stringify_map(attrs)
    company_id = Map.get(attrs, "company_id")

    cond do
      is_nil(company_id) or company_id == "" ->
        {:error, :company_id_required}

      true ->
        %EvaluationSuite{}
        |> EvaluationSuite.changeset(atomize_known_keys(attrs))
        |> Repo.insert()
    end
  end

  def list_suites(company_id) when is_binary(company_id) do
    from(s in EvaluationSuite,
      where: s.company_id == ^company_id,
      order_by: [asc: s.name, asc: s.id]
    )
    |> Repo.all()
  end

  def list_suites(nil), do: []
  def list_suites(_), do: []

  def get_suite(id) when is_binary(id) do
    case Repo.get(EvaluationSuite, id) do
      nil -> {:error, :not_found}
      suite -> {:ok, suite}
    end
  end

  @doc """
  Tenant-scoped suite getter. Cross-tenant IDs return `{:error, :not_found}`.
  """
  def get_company_suite(company_id, id)
      when is_binary(company_id) and is_binary(id) do
    case Repo.one(from(s in EvaluationSuite, where: s.id == ^id and s.company_id == ^company_id)) do
      nil -> {:error, :not_found}
      suite -> {:ok, suite}
    end
  end

  def get_company_suite(_, _), do: {:error, :not_found}

  # ── Runs ────────────────────────────────────────────────────────────────

  def list_runs(company_id, opts \\ [])

  def list_runs(company_id, opts) when is_binary(company_id) do
    suite_id = Keyword.get(opts, :suite_id)
    status = Keyword.get(opts, :status)
    limit = Keyword.get(opts, :limit, 50)

    query =
      from(r in EvaluationRun,
        where: r.company_id == ^company_id,
        order_by: [desc: r.inserted_at, desc: r.id],
        limit: ^limit,
        preload: [:suite]
      )

    query =
      if suite_id do
        where(query, [r], r.suite_id == ^suite_id)
      else
        query
      end

    query =
      if status do
        where(query, [r], r.status == ^to_string(status))
      else
        query
      end

    Repo.all(query)
  end

  def list_runs(nil, _opts), do: []
  def list_runs(_, _opts), do: []

  def get_run(id) when is_binary(id) do
    case Repo.get(EvaluationRun, id) do
      nil -> {:error, :not_found}
      run -> {:ok, Repo.preload(run, [:suite, :results, :feedback])}
    end
  end

  def get_company_run(company_id, id)
      when is_binary(company_id) and is_binary(id) do
    case Repo.one(from(r in EvaluationRun, where: r.id == ^id and r.company_id == ^company_id)) do
      nil -> {:error, :not_found}
      run -> {:ok, Repo.preload(run, [:suite, :results, :feedback])}
    end
  end

  def get_company_run(_, _), do: {:error, :not_found}

  def list_results(%EvaluationRun{id: run_id, company_id: company_id}) do
    list_results(company_id, run_id)
  end

  def list_results(company_id, run_id)
      when is_binary(company_id) and is_binary(run_id) do
    from(r in EvaluationResult,
      where: r.company_id == ^company_id and r.run_id == ^run_id,
      order_by: [asc: r.case_key, asc: r.id]
    )
    |> Repo.all()
  end

  def list_results(_, _), do: []

  # ── Run suite ───────────────────────────────────────────────────────────

  @doc """
  Executes a suite deterministically and persists an immutable run + results.

  Options (keyword or map):
  - `:company_id` — required when suite is passed by id without preload
  - `:trigger` — `"manual"` | `"rerun"` | `"scheduled"` (default `"manual"`)
  - `:parent_run_id` — set by `rerun_suite/2`
  - `:model`, `:prompt`, `:adapter`, `:skills`, `:runtime_profile`, `:metadata`
  - `:role` — override suite role for prompt_contract
  """
  def run_suite(suite, opts \\ [])

  def run_suite(%EvaluationSuite{} = suite, opts) do
    opts = normalize_opts(opts)
    company_id = Map.get(opts, :company_id) || suite.company_id

    with :ok <- require_company(company_id),
         :ok <- assert_same_company(suite.company_id, company_id),
         :ok <- assert_enabled(suite) do
      do_run_suite(suite, company_id, opts)
    end
  end

  def run_suite(suite_id, opts) when is_binary(suite_id) do
    opts = normalize_opts(opts)
    company_id = Map.get(opts, :company_id)

    with :ok <- require_company(company_id),
         {:ok, suite} <- get_company_suite(company_id, suite_id) do
      run_suite(suite, opts)
    end
  end

  defp do_run_suite(suite, company_id, opts) do
    now = utc_now()
    provenance = build_provenance(suite, opts)
    metadata = redact_map(Map.get(opts, :metadata) || %{})
    trigger = opts |> Map.get(:trigger, "manual") |> to_string()

    run_attrs = %{
      company_id: company_id,
      suite_id: suite.id,
      status: "running",
      trigger: trigger,
      parent_run_id: Map.get(opts, :parent_run_id),
      provenance: provenance,
      summary: %{},
      redacted_metadata: metadata,
      started_at: now
    }

    case_outcomes = evaluate_suite_cases(suite, opts)

    case Repo.transaction(fn ->
           with {:ok, run} <-
                  %EvaluationRun{}
                  |> EvaluationRun.create_changeset(run_attrs)
                  |> Repo.insert(),
                :ok <- insert_results(run, suite, company_id, case_outcomes) do
             results = list_results(company_id, run.id)
             summary = build_summary(results)

             run
             |> EvaluationRun.status_changeset(%{
               status: "completed",
               summary: summary,
               completed_at: utc_now()
             })
             |> Repo.update()
             |> case do
               {:ok, run} -> Repo.preload(run, [:suite, :results, :feedback])
               {:error, changeset} -> Repo.rollback(changeset)
             end
           else
             {:error, changeset} -> Repo.rollback(changeset)
           end
         end) do
      {:ok, run} -> {:ok, run}
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_results(run, suite, company_id, case_outcomes) do
    Enum.reduce_while(case_outcomes, :ok, fn outcome, :ok ->
      result =
        %EvaluationResult{}
        |> EvaluationResult.changeset(%{
          company_id: company_id,
          run_id: run.id,
          suite_id: suite.id,
          case_key: outcome.case_key,
          case_label: outcome.case_label,
          kind: outcome.kind,
          expectation: outcome.expectation,
          passed: outcome.passed,
          audit_status: outcome.audit_status,
          audit_summary: outcome.audit_summary,
          gap_fields: outcome.gap_fields,
          validated_fields: outcome.validated_fields,
          redacted_trace: outcome.redacted_trace,
          score: outcome.score
        })
        |> Repo.insert()

      case result do
        {:ok, _} -> {:cont, :ok}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  # ── Rerun ───────────────────────────────────────────────────────────────

  @doc """
  Deterministically re-runs the suite that produced `run`, linking via
  `parent_run_id` and reusing prior provenance inputs (hashes re-derived).
  """
  def rerun_suite(run, opts \\ [])

  def rerun_suite(%EvaluationRun{} = run, opts) do
    opts = normalize_opts(opts)
    company_id = Map.get(opts, :company_id) || run.company_id

    with :ok <- require_company(company_id),
         :ok <- assert_same_company(run.company_id, company_id),
         {:ok, suite} <- get_company_suite(company_id, run.suite_id) do
      prior = run.provenance || %{}

      # Prefer stored skill_hashes over re-hashing skill refs (which only keep ids).
      skills =
        Map.get(opts, :skills) ||
          skills_from_provenance(prior)

      rerun_opts =
        opts
        |> Map.put(:company_id, company_id)
        |> Map.put(:trigger, "rerun")
        |> Map.put(:parent_run_id, run.id)
        |> Map.put_new(:model, prior["model"])
        |> Map.put_new(:prompt, prior["prompt"])
        |> Map.put_new(:adapter, prior["adapter"])
        |> Map.put_new(:role, prior["role"] || suite.role)
        |> Map.put_new(:runtime_profile, prior["runtime_profile"] || %{})
        |> Map.put(:skills, skills)
        |> Map.put(:skill_hashes, prior["skill_hashes"] || %{})

      run_suite(suite, rerun_opts)
    end
  end

  def rerun_suite(run_id, opts) when is_binary(run_id) do
    opts = normalize_opts(opts)
    company_id = Map.get(opts, :company_id)

    with :ok <- require_company(company_id),
         {:ok, run} <- get_company_run(company_id, run_id) do
      rerun_suite(run, opts)
    end
  end

  # ── Feedback ────────────────────────────────────────────────────────────

  @doc """
  Records append-only owner feedback on a completed run.

  `attrs` requires `:vote` (`agree` | `disagree` | `neutral`). Optional:
  `:reason`, `:actor_type`, `:actor_id`, `:result_id`.
  """
  def record_feedback(%EvaluationRun{} = run, attrs) when is_map(attrs) do
    attrs = stringify_map(attrs)

    feedback_attrs = %{
      company_id: run.company_id,
      run_id: run.id,
      result_id: Map.get(attrs, "result_id"),
      vote: Map.get(attrs, "vote"),
      reason: Map.get(attrs, "reason"),
      actor_type: Map.get(attrs, "actor_type") || "user",
      actor_id: Map.get(attrs, "actor_id")
    }

    with :ok <- maybe_validate_result_scope(run, feedback_attrs.result_id) do
      %EvaluationFeedback{}
      |> EvaluationFeedback.changeset(feedback_attrs)
      |> Repo.insert()
    end
  end

  def record_feedback(run_id, attrs) when is_binary(run_id) and is_map(attrs) do
    attrs = stringify_map(attrs)
    company_id = Map.get(attrs, "company_id")

    cond do
      is_nil(company_id) or company_id == "" ->
        # Fail closed: id-only path requires company scope to avoid cross-tenant write.
        {:error, :company_id_required}

      true ->
        with {:ok, run} <- get_company_run(company_id, run_id) do
          record_feedback(run, attrs)
        end
    end
  end

  def list_feedback(%EvaluationRun{id: run_id, company_id: company_id}) do
    list_feedback(company_id, run_id)
  end

  def list_feedback(company_id, run_id)
      when is_binary(company_id) and is_binary(run_id) do
    from(f in EvaluationFeedback,
      where: f.company_id == ^company_id and f.run_id == ^run_id,
      order_by: [desc: f.inserted_at, desc: f.id]
    )
    |> Repo.all()
  end

  def list_feedback(_, _), do: []

  # ── Compare ─────────────────────────────────────────────────────────────

  @doc """
  Compares two evaluation runs case-by-case.

  Returns a map with flipped/improved/regressed cases and provenance equality.
  Both runs must belong to the same company; otherwise `{:error, :tenant_mismatch}`.
  """
  def compare_runs(%EvaluationRun{} = a, %EvaluationRun{} = b) do
    if a.company_id != b.company_id do
      {:error, :tenant_mismatch}
    else
      a = Repo.preload(a, :results)
      b = Repo.preload(b, :results)
      {:ok, build_comparison(a, b)}
    end
  end

  def compare_runs(a_id, b_id) when is_binary(a_id) and is_binary(b_id) do
    with {:ok, a} <- get_run(a_id),
         {:ok, b} <- get_run(b_id) do
      compare_runs(a, b)
    end
  end

  def compare_runs(a_id, b_id, company_id)
      when is_binary(a_id) and is_binary(b_id) and is_binary(company_id) do
    with {:ok, a} <- get_company_run(company_id, a_id),
         {:ok, b} <- get_company_run(company_id, b_id) do
      compare_runs(a, b)
    end
  end

  defp build_comparison(a, b) do
    a_by_key = Map.new(a.results, &{&1.case_key, &1})
    b_by_key = Map.new(b.results, &{&1.case_key, &1})
    keys = MapSet.union(MapSet.new(Map.keys(a_by_key)), MapSet.new(Map.keys(b_by_key)))

    {flipped, improved, regressed, unchanged, only_a, only_b} =
      Enum.reduce(keys, {[], [], [], 0, [], []}, fn key,
                                                    {flipped, improved, regressed, unchanged,
                                                     only_a, only_b} ->
        case {Map.get(a_by_key, key), Map.get(b_by_key, key)} do
          {nil, br} ->
            {flipped, improved, regressed, unchanged, only_a, [case_diff(key, nil, br) | only_b]}

          {ar, nil} ->
            {flipped, improved, regressed, unchanged, [case_diff(key, ar, nil) | only_a], only_b}

          {%{passed: same}, %{passed: same}} ->
            {flipped, improved, regressed, unchanged + 1, only_a, only_b}

          {%{passed: false}, %{passed: true} = br} ->
            ar = a_by_key[key]
            diff = case_diff(key, ar, br)
            {[diff | flipped], [diff | improved], regressed, unchanged, only_a, only_b}

          {%{passed: true}, %{passed: false} = br} ->
            ar = a_by_key[key]
            diff = case_diff(key, ar, br)
            {[diff | flipped], improved, [diff | regressed], unchanged, only_a, only_b}
        end
      end)

    a_passed = count_passed(a.results)
    b_passed = count_passed(b.results)

    %{
      run_a_id: a.id,
      run_b_id: b.id,
      company_id: a.company_id,
      same_suite?: a.suite_id == b.suite_id,
      same_company?: true,
      provenance_equal?: provenance_equal?(a.provenance, b.provenance),
      suite_hash_a: get_in(a.provenance, ["suite_hash"]),
      suite_hash_b: get_in(b.provenance, ["suite_hash"]),
      model_hash_a: get_in(a.provenance, ["model_hash"]),
      model_hash_b: get_in(b.provenance, ["model_hash"]),
      prompt_hash_a: get_in(a.provenance, ["prompt_hash"]),
      prompt_hash_b: get_in(b.provenance, ["prompt_hash"]),
      total_a: length(a.results),
      total_b: length(b.results),
      passed_a: a_passed,
      passed_b: b_passed,
      passed_delta: b_passed - a_passed,
      flipped: Enum.reverse(flipped),
      improved: Enum.reverse(improved),
      regressed: Enum.reverse(regressed),
      unchanged: unchanged,
      only_in_a: Enum.reverse(only_a),
      only_in_b: Enum.reverse(only_b),
      summary_a: a.summary,
      summary_b: b.summary
    }
  end

  defp case_diff(key, nil, b) do
    %{
      case_key: key,
      a_passed: nil,
      b_passed: b.passed,
      a_summary: nil,
      b_summary: b.audit_summary
    }
  end

  defp case_diff(key, a, nil) do
    %{
      case_key: key,
      a_passed: a.passed,
      b_passed: nil,
      a_summary: a.audit_summary,
      b_summary: nil
    }
  end

  defp case_diff(key, a, b) do
    %{
      case_key: key,
      a_passed: a.passed,
      b_passed: b.passed,
      a_summary: a.audit_summary,
      b_summary: b.audit_summary
    }
  end

  defp count_passed(results), do: Enum.count(results, & &1.passed)

  defp provenance_equal?(a, b) when is_map(a) and is_map(b) do
    comparable_keys = ~w(model_hash prompt_hash suite_hash skill_hashes)

    Enum.all?(comparable_keys, fn k ->
      Map.get(a, k) == Map.get(b, k)
    end)
  end

  defp provenance_equal?(_, _), do: false

  # ── Evaluation engines ──────────────────────────────────────────────────

  defp evaluate_suite_cases(%EvaluationSuite{kind: "prompt_contract"} = suite, opts) do
    role = Map.get(opts, :role) || suite.role || "engineer"

    evaluation = AgentPromptContractEval.evaluate(role)

    Enum.map(evaluation.results, fn r ->
      case_key = r.id |> to_string()
      kind = r.kind |> to_string()
      expectation = r.expectation |> to_string()

      %{
        case_key: case_key,
        case_label: Map.get(r, :label) || case_key,
        kind: kind,
        expectation: expectation,
        passed: r.passed? == true,
        audit_status: to_string(Map.get(r, :status) || :unknown),
        audit_summary: Map.get(r, :audit_summary) || "",
        gap_fields: List.wrap(Map.get(r, :gap_fields) || []),
        validated_fields: List.wrap(Map.get(r, :validated_fields) || []),
        redacted_trace:
          redact_map(%{
            "role" => to_string(role),
            "expectation" => expectation,
            "kind" => kind,
            "body_hash" => hash_string(Map.get(r, :body) || "")
          }),
        score: if(r.passed?, do: 1, else: 0)
      }
    end)
  end

  defp evaluate_suite_cases(%EvaluationSuite{kind: "custom"} = suite, _opts) do
    items = EvaluationSuite.case_items(suite)

    Enum.map(items, fn raw ->
      item = stringify_map(raw)
      case_key = Map.get(item, "id") || Map.get(item, "case_key") || hash_string(inspect(item))
      expectation = Map.get(item, "expectation", "pass")
      expected_pass = expectation in ["pass", "pass?", true, "true"]

      actual_pass =
        cond do
          Map.has_key?(item, "actual_pass") ->
            truthy?(Map.get(item, "actual_pass"))

          Map.has_key?(item, "passed") ->
            truthy?(Map.get(item, "passed"))

          is_binary(Map.get(item, "body")) and is_binary(Map.get(item, "role")) ->
            audit_custom_role_body(item)

          true ->
            # Deterministic fixture: default to expected when no body provided
            expected_pass
        end

      passed =
        case expectation do
          "catch" -> not actual_pass
          "fail" -> not actual_pass
          _ -> actual_pass == true
        end

      %{
        case_key: to_string(case_key),
        case_label: Map.get(item, "label") || Map.get(item, "name") || to_string(case_key),
        kind: Map.get(item, "kind") || "custom",
        expectation: to_string(expectation),
        passed: passed,
        audit_status: if(passed, do: "ok", else: "attention"),
        audit_summary:
          Map.get(item, "summary") ||
            if(passed, do: "case passed", else: "case failed"),
        gap_fields: List.wrap(Map.get(item, "gap_fields") || []),
        validated_fields: List.wrap(Map.get(item, "validated_fields") || []),
        redacted_trace:
          redact_map(%{
            "case_key" => to_string(case_key),
            "body_hash" => hash_string(Map.get(item, "body") || ""),
            "metadata" => Map.get(item, "metadata") || %{}
          }),
        score: if(passed, do: 1, else: 0)
      }
    end)
  end

  defp evaluate_suite_cases(suite, opts) do
    evaluate_suite_cases(%{suite | kind: "custom"}, opts)
  end

  defp audit_custom_role_body(item) do
    role = String.to_existing_atom(Map.get(item, "role"))
    body = Map.get(item, "body")
    example = %{role: role, body: body, kind: :role_output, expectation: :pass, id: :custom}
    audited = AgentPromptContractEval.audit_example(example)
    audited.passed? == true
  rescue
    _ -> false
  end

  defp build_summary(results) do
    total = length(results)
    passed = Enum.count(results, & &1.passed)
    failed = total - passed

    %{
      "total" => total,
      "passed" => passed,
      "failed" => failed,
      "pass_rate" => if(total == 0, do: 0.0, else: Float.round(passed / total, 4))
    }
  end

  # ── Provenance ──────────────────────────────────────────────────────────

  defp build_provenance(suite, opts) do
    model = opts |> Map.get(:model) |> present_or("deterministic-fixture")
    prompt = opts |> Map.get(:prompt) |> present_or(suite.role || "")
    adapter = opts |> Map.get(:adapter)
    role = opts |> Map.get(:role) || suite.role
    runtime = redact_map(Map.get(opts, :runtime_profile) || %{})
    skills = normalize_skills(Map.get(opts, :skills) || [])
    prior_hashes = Map.get(opts, :skill_hashes) || %{}

    skill_hashes = build_skill_hashes(skills, prior_hashes)

    # Persist skill content hashes only — never raw secret-bearing skill bodies.
    %{
      "model" => model,
      "model_hash" => hash_string(model),
      "prompt" => if(is_binary(prompt) and String.length(prompt) <= 200, do: prompt, else: nil),
      "prompt_hash" => hash_string(to_string(prompt)),
      "suite_hash" => suite_hash(suite),
      "skill_hashes" => skill_hashes,
      "skills" => Enum.map(skills, &skill_ref(&1, skill_hashes)),
      "runtime_profile" => runtime,
      "adapter" => adapter && to_string(adapter),
      "role" => role && to_string(role),
      "kind" => suite.kind,
      "redacted" => true
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp build_skill_hashes(skills, prior_hashes)
       when is_map(prior_hashes) and map_size(prior_hashes) > 0 do
    # Rerun path: prefer prior immutable hashes when content bodies are unavailable.
    from_skills =
      Map.new(skills, fn skill ->
        id = skill_id(skill)
        content = Map.get(skill, "content") || Map.get(skill, :content)

        hash =
          cond do
            is_binary(content) and content != "" -> hash_string(content)
            is_binary(Map.get(skill, "content_hash")) -> Map.get(skill, "content_hash")
            true -> Map.get(prior_hashes, id) || Map.get(prior_hashes, to_string(id))
          end

        {to_string(id), hash}
      end)

    Map.merge(stringify_map(prior_hashes), from_skills)
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp build_skill_hashes(skills, _prior_hashes) do
    Map.new(skills, fn skill ->
      id = skill_id(skill)
      content = Map.get(skill, "content") || Map.get(skill, :content) || ""
      content_hash = Map.get(skill, "content_hash")

      hash =
        if is_binary(content_hash) and content_hash != "" do
          content_hash
        else
          hash_string(to_string(content))
        end

      {to_string(id), hash}
    end)
  end

  defp skill_id(skill) do
    Map.get(skill, "id") || Map.get(skill, :id) || hash_string(inspect(skill))
  end

  defp skill_ref(skill, skill_hashes) do
    skill = stringify_map(skill)
    id = to_string(Map.get(skill, "id") || "")

    %{
      "id" => Map.get(skill, "id"),
      "content_hash" => Map.get(skill_hashes, id) || Map.get(skill, "content_hash")
    }
  end

  defp skills_from_provenance(%{"skills" => skills}) when is_list(skills), do: skills

  defp skills_from_provenance(%{"skill_hashes" => hashes}) when is_map(hashes) do
    Enum.map(hashes, fn {id, hash} -> %{"id" => id, "content_hash" => hash} end)
  end

  defp skills_from_provenance(_), do: []

  defp suite_hash(%EvaluationSuite{} = suite) do
    payload = %{
      identifier: suite.identifier,
      kind: suite.kind,
      role: suite.role,
      cases: EvaluationSuite.case_items(suite),
      config: suite.config || %{}
    }

    hash_string(:erlang.term_to_binary(payload))
  end

  defp hash_string(data) when is_binary(data) do
    :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
  end

  defp hash_string(data), do: hash_string(to_string(data))

  # ── Redaction ───────────────────────────────────────────────────────────

  def redact_map(value) when is_map(value) do
    Map.new(value, fn {k, v} ->
      key = to_string(k)

      if secret_key?(key) do
        {key, @redacted_placeholder}
      else
        {key, redact_value(v)}
      end
    end)
  end

  def redact_map(value) when is_list(value), do: Enum.map(value, &redact_value/1)
  def redact_map(value), do: value

  defp redact_value(v) when is_map(v), do: redact_map(v)
  defp redact_value(v) when is_list(v), do: Enum.map(v, &redact_value/1)
  defp redact_value(v) when is_binary(v), do: redact_binary(v)
  defp redact_value(v), do: v

  defp redact_binary(bin) do
    bin
    |> String.replace(~r/\bsk-[A-Za-z0-9_-]{8,}\b/i, @redacted_placeholder)
    |> String.replace(~r/\bbearer\s+[A-Za-z0-9._~+\/-]{12,}/i, @redacted_placeholder)
  end

  defp secret_key?(key) do
    lowered = String.downcase(key)

    MapSet.member?(@secret_fields, lowered) or
      Enum.any?(@secret_field_suffixes, &String.ends_with?(lowered, &1))
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp require_company(id) when is_binary(id) and id != "", do: :ok
  defp require_company(_), do: {:error, :company_id_required}

  defp assert_same_company(a, b) when a == b, do: :ok
  defp assert_same_company(_, _), do: {:error, :tenant_mismatch}

  defp assert_enabled(%EvaluationSuite{enabled: true}), do: :ok
  defp assert_enabled(%EvaluationSuite{}), do: {:error, :suite_disabled}

  defp maybe_validate_result_scope(_run, nil), do: :ok

  defp maybe_validate_result_scope(run, result_id) when is_binary(result_id) do
    case Repo.one(
           from(r in EvaluationResult,
             where: r.id == ^result_id and r.run_id == ^run.id and r.company_id == ^run.company_id
           )
         ) do
      nil -> {:error, :not_found}
      _ -> :ok
    end
  end

  defp maybe_validate_result_scope(_, _), do: {:error, :not_found}

  defp normalize_opts(opts) when is_list(opts), do: Map.new(opts)
  defp normalize_opts(opts) when is_map(opts), do: atomize_option_keys(opts)
  defp normalize_opts(_), do: %{}

  @option_keys ~w(company_id trigger parent_run_id model prompt adapter role skills skill_hashes runtime_profile metadata)

  defp atomize_option_keys(map) do
    Enum.reduce(@option_keys, %{}, fn key, acc ->
      atom = String.to_existing_atom(key)

      cond do
        Map.has_key?(map, atom) -> Map.put(acc, atom, Map.get(map, atom))
        Map.has_key?(map, key) -> Map.put(acc, atom, Map.get(map, key))
        true -> acc
      end
    end)
  end

  defp atomize_known_keys(attrs) do
    known = ~w(company_id name identifier description kind role cases config enabled)

    Enum.reduce(known, %{}, fn key, acc ->
      cond do
        Map.has_key?(attrs, key) ->
          Map.put(acc, String.to_existing_atom(key), Map.get(attrs, key))

        Map.has_key?(attrs, String.to_existing_atom(key)) ->
          Map.put(acc, String.to_existing_atom(key), Map.get(attrs, String.to_existing_atom(key)))

        true ->
          acc
      end
    end)
  end

  defp stringify_map(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp stringify_map(_), do: %{}

  defp normalize_skills(skills) when is_list(skills) do
    Enum.map(skills, &stringify_map/1)
  end

  defp normalize_skills(_), do: []

  defp present_or(nil, fallback), do: fallback
  defp present_or("", fallback), do: fallback
  defp present_or(value, _fallback), do: value

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(1), do: true
  defp truthy?("1"), do: true
  defp truthy?(_), do: false

  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
