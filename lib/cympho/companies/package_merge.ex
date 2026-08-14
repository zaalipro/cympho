defmodule Cympho.Companies.PackageMerge do
  @moduledoc """
  Merges a portable company package into an *existing* company.

  Whole-package import (`Cympho.Companies.import_company/2`) always creates a new
  company. Merge is the other half of the portability story: applying a standard
  package — a role template, a label taxonomy, a project scaffold — on top of a
  company that already has data.

  ## Collision modes

  Each incoming record is matched against the target company by a natural key
  (label name, project prefix, agent name, goal title). When a match exists:

  * `:skip` — keep the existing record; references in the package remap to it
  * `:replace` — update the existing record from the package; references remap to it
  * `:rename` — always write a new record under a de-duplicated natural key
  * `:fail` — abort the whole merge, changing nothing

  Records with no match are always created.

  ## What merges

  Only blueprint collections merge: `labels`, `projects`, `goals`, `agents`.
  Identity (`users`, `memberships`), operational history (`issues`), and the
  `secret_manifest` are reported as unsupported rather than silently dropped —
  merging them by name into a live company would fabricate identity or duplicate
  work items. Use whole-company import for those.

  ## Safety

  * `preview/3` writes nothing and is the dry run for `apply/3`.
  * Packages are structurally validated through `Portability.preview_import/2`
    first, so a malformed package never reaches a writer.
  * Redacted secret placeholders are stripped, never persisted as values.
  * Created and replaced agents land paused with heartbeat timers disabled, so a
    merge cannot start work in a live company on its own.
  """

  import Ecto.Query, warn: false

  alias Cympho.Agents.Agent
  alias Cympho.Companies.Company
  alias Cympho.Companies.Portability
  alias Cympho.Goals.Goal
  alias Cympho.Labels.Label
  alias Cympho.Projects.Project
  alias Cympho.Repo

  @collision_modes [:skip, :replace, :rename, :fail]
  @mergeable [:labels, :projects, :goals, :agents]
  @unsupported [
    {:users, "identity is never merged by name; use whole-company import"},
    {:memberships, "membership follows identity and is never merged"},
    {:issues, "issues are operational history, not blueprint content"},
    {:secret_manifest, "secret values are never carried by a package"}
  ]

  @redacted_secret_marker "***REDACTED***"

  @doc """
  Collision modes accepted by `preview/3` and `apply/3`.
  """
  def collision_modes, do: @collision_modes

  @doc """
  Collections this module can merge.
  """
  def mergeable_collections, do: @mergeable

  @doc """
  Dry run. Returns the per-collection plan without writing anything.

  Options:
  * `:collision` — one of `collision_modes/0`, default `:skip`
  * `:includes` — `:all` or a list of collection keys
  """
  @spec preview(map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def preview(data, company_id, opts \\ []) do
    with {:ok, context} <- build_context(data, company_id, opts) do
      {:ok, context.plan}
    end
  end

  @doc """
  Applies the merge in a single transaction.

  Returns `{:ok, %{plan: plan, id_maps: id_maps, applied: counts}}`. A `:fail`
  collision mode with any conflict returns `{:error, {:collision, conflicts}}`
  before any write.
  """
  @spec apply(map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def apply(data, company_id, opts \\ []) do
    with {:ok, context} <- build_context(data, company_id, opts) do
      Repo.transaction(fn ->
        id_maps =
          Enum.reduce(@mergeable, %{}, fn collection, acc ->
            Map.put(acc, collection, write_collection(collection, context, acc))
          end)

        link_parents(context, id_maps)

        %{plan: context.plan, id_maps: id_maps, applied: context.plan.totals}
      end)
    end
  end

  # --- Planning ---------------------------------------------------------------

  defp build_context(data, company_id, opts) when is_map(data) and is_binary(company_id) do
    collision = Keyword.get(opts, :collision, :skip)
    includes = Portability.normalize_includes(Keyword.get(opts, :includes, :all))

    with :ok <- validate_collision(collision),
         {:ok, includes} <- validate_includes(includes),
         {:ok, company} <- fetch_company(company_id),
         {:ok, _preview} <- Portability.preview_import(data, slug_strategy: :suffix) do
      records = collect_records(data, includes)
      existing = load_existing(company.id)
      decisions = decide(records, existing, collision)

      case collision do
        :fail ->
          case conflicts(decisions) do
            [] -> {:ok, context(company, collision, includes, records, existing, decisions)}
            found -> {:error, {:collision, found}}
          end

        _ ->
          {:ok, context(company, collision, includes, records, existing, decisions)}
      end
    end
  end

  defp build_context(_data, _company_id, _opts), do: {:error, :invalid_arguments}

  defp context(company, collision, includes, records, existing, decisions) do
    %{
      company: company,
      collision: collision,
      includes: includes,
      records: records,
      existing: existing,
      decisions: decisions,
      plan: build_plan(company, collision, includes, decisions)
    }
  end

  defp validate_collision(mode) when mode in @collision_modes, do: :ok
  defp validate_collision(mode), do: {:error, {:unsupported_collision_mode, mode}}

  defp validate_includes({:error, reason}), do: {:error, {:unsupported_includes, reason}}
  defp validate_includes(includes), do: {:ok, includes}

  defp fetch_company(company_id) do
    case Repo.get(Company, company_id) do
      nil -> {:error, :company_not_found}
      company -> {:ok, company}
    end
  end

  defp collect_records(data, includes) do
    Map.new(@mergeable, fn collection ->
      if included?(collection, includes) do
        {collection, List.wrap(field(data, collection, []))}
      else
        {collection, []}
      end
    end)
  end

  defp included?(_collection, :all), do: true
  defp included?(collection, includes) when is_list(includes), do: collection in includes

  defp load_existing(company_id) do
    %{
      labels: index(Repo.all(from(l in Label, where: l.company_id == ^company_id)), :labels),
      projects:
        index(Repo.all(from(p in Project, where: p.company_id == ^company_id)), :projects),
      goals: index(Repo.all(from(g in Goal, where: g.company_id == ^company_id)), :goals),
      agents: index(Repo.all(from(a in Agent, where: a.company_id == ^company_id)), :agents)
    }
  end

  defp index(records, collection) do
    Map.new(records, fn record -> {natural_key(collection, record), record} end)
  end

  # Each collection's natural key is the field an operator would call "the same
  # thing" across two companies.
  defp natural_key(:labels, record), do: normalize_key(field(record, :name))

  defp natural_key(:projects, record),
    do: normalize_key(field(record, :prefix) || field(record, :name))

  defp natural_key(:goals, record), do: normalize_key(field(record, :title))
  defp natural_key(:agents, record), do: normalize_key(field(record, :name))

  defp normalize_key(nil), do: nil
  defp normalize_key(value), do: value |> to_string() |> String.trim() |> String.downcase()

  defp decide(records, existing, collision) do
    Map.new(@mergeable, fn collection ->
      incoming = Map.fetch!(records, collection)
      existing_index = Map.fetch!(existing, collection)

      {decisions, _seen} =
        Enum.map_reduce(incoming, MapSet.new(), fn record, seen ->
          key = natural_key(collection, record)

          decision =
            cond do
              is_nil(key) ->
                %{action: :create, key: key, record: record, existing: nil}

              Map.has_key?(existing_index, key) or MapSet.member?(seen, key) ->
                %{
                  action: collision_action(collision),
                  key: key,
                  record: record,
                  existing: Map.get(existing_index, key)
                }

              true ->
                %{action: :create, key: key, record: record, existing: nil}
            end

          {decision, if(key, do: MapSet.put(seen, key), else: seen)}
        end)

      {collection, decisions}
    end)
  end

  defp collision_action(:skip), do: :skip
  defp collision_action(:replace), do: :replace
  defp collision_action(:rename), do: :rename
  # `:fail` is rejected before any write; treat it as skip while planning so the
  # conflict list can still be reported.
  defp collision_action(:fail), do: :skip

  defp conflicts(decisions) do
    Enum.flat_map(@mergeable, fn collection ->
      decisions
      |> Map.fetch!(collection)
      |> Enum.filter(&(&1.existing != nil))
      |> Enum.map(&%{collection: collection, key: &1.key, existing_id: &1.existing.id})
    end)
  end

  defp build_plan(company, collision, includes, decisions) do
    collections =
      Enum.map(@mergeable, fn collection ->
        rows = Map.fetch!(decisions, collection)

        %{
          collection: collection,
          create: count(rows, :create),
          skip: count(rows, :skip),
          replace: count(rows, :replace),
          rename: count(rows, :rename),
          conflicts:
            rows
            |> Enum.filter(&(&1.existing != nil))
            |> Enum.map(&%{key: &1.key, action: &1.action, existing_id: &1.existing.id})
        }
      end)

    %{
      target_company: %{id: company.id, name: company.name, slug: company.slug},
      collision: collision,
      includes: includes,
      collections: collections,
      unsupported:
        Enum.map(@unsupported, fn {key, reason} -> %{collection: key, reason: reason} end),
      totals: %{
        create: sum(collections, :create),
        skip: sum(collections, :skip),
        replace: sum(collections, :replace),
        rename: sum(collections, :rename)
      },
      warnings: plan_warnings(collections)
    }
  end

  defp count(rows, action), do: Enum.count(rows, &(&1.action == action))
  defp sum(collections, key), do: Enum.reduce(collections, 0, &(&1[key] + &2))

  defp plan_warnings(collections) do
    Enum.flat_map(collections, fn entry ->
      cond do
        entry.replace > 0 ->
          [
            %{
              code: :records_replaced,
              message:
                "#{entry.replace} existing #{entry.collection} record(s) will be overwritten from the package."
            }
          ]

        true ->
          []
      end
    end)
  end

  # --- Writing ----------------------------------------------------------------

  defp write_collection(collection, context, id_maps) do
    context.decisions
    |> Map.fetch!(collection)
    |> Enum.reduce(%{}, fn decision, acc ->
      source = source_id(decision.record)

      case decision.action do
        :skip ->
          put_id(acc, source, decision.existing.id)

        :replace ->
          record = update!(collection, decision.existing, decision.record, context, id_maps)
          put_id(acc, source, record.id)

        :rename ->
          key = unique_key(collection, decision.key, context)
          record = insert!(collection, decision.record, context, id_maps, key)
          put_id(acc, source, record.id)

        :create ->
          record = insert!(collection, decision.record, context, id_maps, nil)
          put_id(acc, source, record.id)
      end
    end)
  end

  defp put_id(map, nil, _id), do: map
  defp put_id(map, source, id), do: Map.put(map, source, id)

  defp insert!(collection, record, context, id_maps, renamed_key) do
    collection
    |> schema()
    |> struct()
    |> changeset(collection, attrs(collection, record, context, id_maps, renamed_key))
    |> Repo.insert()
    |> unwrap!(collection)
  end

  defp update!(collection, existing, record, context, id_maps) do
    existing
    |> changeset(collection, attrs(collection, record, context, id_maps, nil))
    |> Repo.update()
    |> unwrap!(collection)
  end

  defp unwrap!({:ok, record}, _collection), do: record

  defp unwrap!({:error, changeset}, collection) do
    Repo.rollback({:invalid_record, collection, changeset_errors(changeset)})
  end

  defp changeset_errors(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)
  end

  defp schema(:labels), do: Label
  defp schema(:projects), do: Project
  defp schema(:goals), do: Goal
  defp schema(:agents), do: Agent

  defp changeset(struct, :labels, attrs), do: Label.changeset(struct, attrs)
  defp changeset(struct, :projects, attrs), do: Project.changeset(struct, attrs)
  defp changeset(struct, :goals, attrs), do: Goal.changeset(struct, attrs)
  defp changeset(struct, :agents, attrs), do: Agent.changeset(struct, attrs)

  defp attrs(:labels, record, context, _id_maps, renamed_key) do
    %{
      name: renamed_key || field(record, :name),
      color: field(record, :color) || "#6B7280",
      description: field(record, :description),
      company_id: context.company.id
    }
  end

  defp attrs(:projects, record, context, _id_maps, renamed_key) do
    %{
      name: field(record, :name),
      description: field(record, :description),
      prefix: renamed_key || field(record, :prefix),
      settings: field(record, :settings) || %{},
      company_id: context.company.id
    }
  end

  defp attrs(:goals, record, context, id_maps, renamed_key) do
    %{
      title: renamed_key || field(record, :title),
      description: field(record, :description),
      status: field(record, :status) || "active",
      priority: field(record, :priority) || "medium",
      goal_type: field(record, :goal_type) || :initiative,
      target_date: field(record, :target_date),
      project_id: remap(id_maps, :projects, field(record, :project_id)),
      company_id: context.company.id
    }
  end

  defp attrs(:agents, record, context, id_maps, renamed_key) do
    %{
      name: renamed_key || field(record, :name),
      url_key: merged_url_key(field(record, :url_key)),
      title: field(record, :title),
      role: field(record, :role) || :engineer,
      adapter: field(record, :adapter),
      config: scrub_placeholders(field(record, :config) || %{}),
      runtime_config: scrub_placeholders(field(record, :runtime_config) || %{}),
      # Timers stay off: a merge must never start work in a live company.
      heartbeat_config:
        record
        |> field(:heartbeat_config)
        |> Kernel.||(%{})
        |> scrub_placeholders()
        |> Map.put("enabled", false)
        |> Map.delete(:enabled),
      capabilities: scrub_placeholders(field(record, :capabilities) || %{}),
      permissions: scrub_placeholders(field(record, :permissions) || %{}),
      budget: scrub_placeholders(field(record, :budget) || %{}),
      icon: field(record, :icon),
      instructions: field(record, :instructions),
      instructions_path: field(record, :instructions_path),
      context_mode: field(record, :context_mode) || "company",
      max_concurrent_jobs: field(record, :max_concurrent_jobs) || 3,
      budget_monthly_cents: field(record, :budget_monthly_cents) || 0,
      status: :paused,
      pause_reason: "Imported via package merge; heartbeat timers disabled.",
      paused_at: DateTime.utc_now() |> DateTime.truncate(:second),
      project_id: remap(id_maps, :projects, field(record, :project_id)),
      company_id: context.company.id
    }
  end

  defp merged_url_key(nil), do: nil
  defp merged_url_key(url_key), do: "#{url_key}-#{:rand.uniform(9999)}"

  # Parents are linked after every record in the collection exists, so forward
  # references inside the package resolve. Skipped records keep their existing
  # hierarchy untouched.
  defp link_parents(context, id_maps) do
    link_parent(context, id_maps, :goals, Goal, :parent_id)
    link_parent(context, id_maps, :agents, Agent, :parent_id)
  end

  defp link_parent(context, id_maps, collection, schema, field_name) do
    collection_ids = Map.fetch!(id_maps, collection)

    context.decisions
    |> Map.fetch!(collection)
    |> Enum.each(fn decision ->
      source_parent = field(decision.record, field_name)
      target_id = Map.get(collection_ids, source_id(decision.record))

      with false <- decision.action == :skip,
           true <- is_binary(source_parent) and is_binary(target_id),
           parent_id when is_binary(parent_id) <- Map.get(collection_ids, source_parent) do
        schema
        |> Repo.get!(target_id)
        |> changeset(collection, %{field_name => parent_id})
        |> Repo.update()
        |> unwrap!(collection)
      else
        _ -> :ok
      end
    end)
  end

  defp remap(id_maps, collection, source_id) when is_binary(source_id) do
    id_maps |> Map.get(collection, %{}) |> Map.get(source_id)
  end

  defp remap(_id_maps, _collection, _source_id), do: nil

  # --- Helpers ----------------------------------------------------------------

  defp unique_key(collection, key, context) do
    taken = context.existing |> Map.fetch!(collection) |> Map.keys() |> MapSet.new()

    1..100
    |> Enum.map(&candidate_key(collection, key, &1))
    |> Enum.find(fn candidate -> not MapSet.member?(taken, normalize_key(candidate)) end)
    |> Kernel.||(candidate_key(collection, key, System.unique_integer([:positive])))
  end

  # Project prefixes are validated as 2-10 uppercase letters, so a renamed
  # prefix gets an alphabetic suffix rather than "-copy".
  defp candidate_key(:projects, key, attempt) do
    base =
      key
      |> to_string()
      |> String.upcase()
      |> String.replace(~r/[^A-Z]+/, "")
      |> case do
        "" -> "PRJ"
        value -> value
      end

    suffix = alpha_suffix(attempt)
    String.slice(base, 0, max(2, 10 - String.length(suffix))) <> suffix
  end

  defp candidate_key(_collection, key, 1), do: "#{key || "imported"}-copy"
  defp candidate_key(_collection, key, attempt), do: "#{key || "imported"}-copy-#{attempt}"

  defp alpha_suffix(n) when n in 1..26, do: <<64 + n::utf8>>
  defp alpha_suffix(n), do: alpha_suffix(div(n - 1, 26)) <> alpha_suffix(rem(n - 1, 26) + 1)

  defp source_id(record), do: field(record, :id)

  defp field(map, key, default \\ nil)

  defp field(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp field(_map, _key, default), do: default

  defp scrub_placeholders(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested}, acc ->
      if nested == @redacted_secret_marker do
        acc
      else
        Map.put(acc, key, scrub_placeholders(nested))
      end
    end)
  end

  defp scrub_placeholders(value) when is_list(value),
    do: value |> Enum.reject(&(&1 == @redacted_secret_marker)) |> Enum.map(&scrub_placeholders/1)

  defp scrub_placeholders(value), do: value
end
