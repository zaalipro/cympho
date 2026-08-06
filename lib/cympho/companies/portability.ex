defmodule Cympho.Companies.Portability do
  @moduledoc """
  Read-only validation and planning for company portability imports.

  Preview plans contain only import metadata. They never retain the uploaded
  package or credential values, and every database operation in this module is
  a read.
  """

  import Ecto.Query, warn: false

  alias Cympho.Companies.Company
  alias Cympho.Repo
  alias Cympho.Users.User

  @supported_versions [1]
  @collection_fields ~w(users memberships projects agents issues goals labels secret_manifest)a
  @identified_collections ~w(users projects agents issues goals labels)a
  @include_fields [:company | @collection_fields]
  @secret_fields ~w(
    value password_hash key_hash encrypted_value webhook_secret github_webhook_secret
    api_key password secret token authorization cookie database_url key credential credentials
    headers env auth authentication secrets
  )
  @secret_field_suffixes ~w(
    _api_key _password _secret _token _authorization _cookie _database_url _key
    _credential _credentials
  )
  @redacted_secret_marker "***REDACTED***"

  def supported_versions, do: @supported_versions

  @doc """
  Collection keys that selective package includes may name.

  `:all` remains the V1 default and preserves whole-package behavior.
  """
  def supported_includes, do: @include_fields

  @doc """
  Normalizes an `:includes` option to `:all` or a list of known atoms.

  Unknown keys are rejected so selective callers fail closed instead of silently
  dropping data.
  """
  def normalize_includes(:all), do: :all
  def normalize_includes(nil), do: :all

  def normalize_includes(includes) when is_list(includes) do
    allowed = MapSet.new(@include_fields)

    normalized =
      Enum.map(includes, fn
        key when is_atom(key) -> key
        key when is_binary(key) -> String.to_existing_atom(key)
      end)

    unknown = Enum.reject(normalized, &MapSet.member?(allowed, &1))

    if unknown == [] do
      Enum.uniq(normalized)
    else
      {:error, unknown}
    end
  rescue
    ArgumentError ->
      {:error, includes}
  end

  def normalize_includes(_includes), do: {:error, :invalid_includes}

  @doc """
  Filters a package map to the requested includes.

  `:all` returns the package unchanged (V1 whole-package default).
  """
  def apply_includes(package, :all) when is_map(package), do: package

  def apply_includes(package, includes) when is_map(package) and is_list(includes) do
    keep =
      includes
      |> Enum.flat_map(fn key -> [key, Atom.to_string(key)] end)
      |> MapSet.new()

    # Always retain package metadata so version/export stamps survive filtering.
    metadata_keys =
      MapSet.new([:version, "version", :exported_at, "exported_at", :format, "format"])

    package
    |> Enum.filter(fn {key, _value} ->
      MapSet.member?(keep, key) or MapSet.member?(metadata_keys, key)
    end)
    |> Map.new()
  end

  def apply_includes(package, _includes), do: package

  @doc """
  Validates and previews a V1 company import without writing any records.
  """
  def preview_import(data, opts \\ [])

  def preview_import(data, opts) when is_map(data) do
    strategy = Keyword.get(opts, :slug_strategy, :suffix)
    includes = normalize_includes(Keyword.get(opts, :includes, :all))

    case includes do
      {:error, _reason} ->
        {:error,
         %{
           errors: [
             error(
               :includes,
               :unsupported_includes,
               "Includes must be :all or a list of supported package collections."
             )
           ],
           supported_versions: @supported_versions,
           supported_includes: @include_fields
         }}

      normalized_includes ->
        errors = validation_errors(data, strategy)

        if errors == [] do
          {:ok, build_plan(data, strategy, normalized_includes)}
        else
          {:error, %{errors: errors, supported_versions: @supported_versions}}
        end
    end
  end

  def preview_import(_data, _opts) do
    {:error,
     %{
       errors: [error(:package, :invalid_package, "Import package must be a JSON object.")],
       supported_versions: @supported_versions
     }}
  end

  defp validation_errors(data, strategy) do
    []
    |> validate_strategy(strategy)
    |> validate_version(data)
    |> validate_company(data)
    |> validate_collections(data)
    |> validate_nested_collections(data)
    |> validate_record_ids(data)
    |> validate_reference_integrity(data)
    |> validate_unredacted_secrets(data)
    |> Enum.sort_by(&{&1.field, &1.code})
  end

  defp validate_strategy(errors, strategy) when strategy in [:suffix, :fail], do: errors

  defp validate_strategy(errors, _strategy) do
    [
      error(:slug_strategy, :unsupported_strategy, "Slug strategy must be suffix or fail.")
      | errors
    ]
  end

  defp validate_version(errors, data) do
    case field(data, :version, :missing) do
      :missing ->
        [error(:version, :missing_version, "Missing export version.") | errors]

      version when version in @supported_versions ->
        errors

      version when is_integer(version) ->
        message =
          "Export version #{version} is not supported. Supported versions: #{Enum.join(@supported_versions, ", ")}"

        [error(:version, :unsupported_version, message) | errors]

      _version ->
        [error(:version, :invalid_version, "Export version must be an integer.") | errors]
    end
  end

  defp validate_company(errors, data) do
    case field(data, :company, :missing) do
      :missing ->
        [error(:company, :missing_company, "Missing company data.") | errors]

      company when is_map(company) ->
        %Company{}
        |> Company.changeset(%{
          name: field(company, :name),
          slug: field(company, :slug),
          logo_url: field(company, :logo_url)
        })
        |> Ecto.Changeset.traverse_errors(&format_changeset_error/1)
        |> Enum.reduce(errors, fn {field_name, messages}, acc ->
          Enum.reduce(messages, acc, fn message, nested ->
            [error("company.#{field_name}", :invalid_company, message) | nested]
          end)
        end)

      _company ->
        [error(:company, :invalid_company, "Company data must be an object.") | errors]
    end
  end

  defp validate_collections(errors, data) do
    Enum.reduce(@collection_fields, errors, fn key, acc ->
      case field(data, key, []) do
        records when is_list(records) ->
          if Enum.all?(records, &is_map/1) do
            acc
          else
            [error(key, :invalid_collection, "#{key} must contain only objects.") | acc]
          end

        _other ->
          [error(key, :invalid_collection, "#{key} must be a list.") | acc]
      end
    end)
  end

  defp validate_nested_collections(errors, data) do
    data
    |> collection(:issues)
    |> Enum.with_index()
    |> Enum.reduce(errors, fn {issue, issue_index}, acc ->
      acc
      |> validate_nested_collection(issue, :comments, "issues.#{issue_index}.comments")
      |> validate_nested_collection(issue, :labels, "issues.#{issue_index}.labels")
    end)
  end

  defp validate_nested_collection(errors, record, key, path) do
    case field(record, key, []) do
      records when is_list(records) ->
        if Enum.all?(records, &is_map/1) do
          errors
        else
          [error(path, :invalid_collection, "#{path} must contain only objects.") | errors]
        end

      _other ->
        [error(path, :invalid_collection, "#{path} must be a list.") | errors]
    end
  end

  defp validate_record_ids(errors, data) do
    errors =
      Enum.reduce(@identified_collections, errors, fn collection_name, acc ->
        records = collection(data, collection_name)

        records
        |> Enum.with_index()
        |> Enum.reduce(acc, fn {record, index}, nested ->
          case field(record, :id) do
            id when is_binary(id) and id != "" ->
              nested

            _id ->
              path = "#{collection_name}.#{index}.id"
              [error(path, :invalid_record_id, "#{path} must be a non-empty string.") | nested]
          end
        end)
        |> validate_unique_record_ids(records, collection_name)
      end)

    validate_unique_user_emails(errors, collection(data, :users))
  end

  defp validate_unique_record_ids(errors, records, collection_name) do
    duplicate_ids =
      records
      |> Enum.map(&field(&1, :id))
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> duplicate_values()

    Enum.reduce(duplicate_ids, errors, fn _duplicate_id, acc ->
      message = "#{collection_name} contains duplicate record IDs."
      [error(collection_name, :duplicate_record_id, message) | acc]
    end)
  end

  defp validate_unique_user_emails(errors, users) do
    duplicate_emails =
      users
      |> Enum.map(&field(&1, :email))
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&(String.trim(&1) |> String.downcase()))
      |> Enum.reject(&(&1 == ""))
      |> duplicate_values()

    if duplicate_emails == [] do
      errors
    else
      [
        error(
          :users,
          :duplicate_user_email,
          "users contains duplicate email addresses, so planned writes would be ambiguous."
        )
        | errors
      ]
    end
  end

  defp duplicate_values(values) do
    values
    |> Enum.frequencies()
    |> Enum.filter(fn {_value, count} -> count > 1 end)
    |> Enum.map(&elem(&1, 0))
  end

  defp validate_reference_integrity(errors, data) do
    ids = %{
      users: ids(data, :users),
      projects: ids(data, :projects),
      agents: ids(data, :agents),
      issues: ids(data, :issues),
      goals: ids(data, :goals),
      labels: ids(data, :labels)
    }

    member_user_ids =
      data
      |> collection(:memberships)
      |> Enum.map(&field(&1, :user_id))
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    errors
    |> validate_membership_references(data, ids)
    |> validate_goal_references(data, ids)
    |> validate_agent_references(data, ids)
    |> validate_issue_references(data, ids, member_user_ids)
    |> validate_secret_scope_references(data, ids)
  end

  defp validate_membership_references(errors, data, ids) do
    memberships = collection(data, :memberships)

    errors =
      memberships
      |> Enum.with_index()
      |> Enum.reduce(errors, fn {membership, index}, acc ->
        validate_reference(
          acc,
          ids.users,
          field(membership, :user_id),
          "memberships.#{index}.user_id",
          required?: true
        )
      end)

    referenced_user_ids = Enum.map(memberships, &field(&1, :user_id))

    if duplicate_values(referenced_user_ids) == [] do
      errors
    else
      [
        error(
          :memberships,
          :duplicate_reference,
          "memberships cannot include the same user more than once."
        )
        | errors
      ]
    end
  end

  defp validate_goal_references(errors, data, ids) do
    data
    |> collection(:goals)
    |> Enum.with_index()
    |> Enum.reduce(errors, fn {goal, index}, acc ->
      acc
      |> validate_reference(ids.projects, field(goal, :project_id), "goals.#{index}.project_id")
      |> validate_reference(ids.goals, field(goal, :parent_id), "goals.#{index}.parent_id")
    end)
  end

  defp validate_agent_references(errors, data, ids) do
    data
    |> collection(:agents)
    |> Enum.with_index()
    |> Enum.reduce(errors, fn {agent, index}, acc ->
      acc
      |> validate_reference(ids.projects, field(agent, :project_id), "agents.#{index}.project_id")
      |> validate_reference(ids.agents, field(agent, :parent_id), "agents.#{index}.parent_id")
      |> validate_reference(
        ids.agents,
        field(agent, :created_by_agent_id),
        "agents.#{index}.created_by_agent_id"
      )
    end)
  end

  defp validate_issue_references(errors, data, ids, member_user_ids) do
    data
    |> collection(:issues)
    |> Enum.with_index()
    |> Enum.reduce(errors, fn {issue, issue_index}, acc ->
      acc
      |> validate_reference(
        ids.projects,
        field(issue, :project_id),
        "issues.#{issue_index}.project_id"
      )
      |> validate_reference(
        ids.agents,
        field(issue, :assignee_id),
        "issues.#{issue_index}.assignee_id"
      )
      |> validate_reference(
        member_user_ids,
        field(issue, :assignee_user_id),
        "issues.#{issue_index}.assignee_user_id"
      )
      |> validate_reference(ids.goals, field(issue, :goal_id), "issues.#{issue_index}.goal_id")
      |> validate_reference(
        ids.issues,
        field(issue, :parent_id),
        "issues.#{issue_index}.parent_id"
      )
      |> validate_reference(
        ids.agents,
        field(issue, :created_by_agent_id),
        "issues.#{issue_index}.created_by_agent_id"
      )
      |> validate_reference(
        member_user_ids,
        field(issue, :created_by_user_id),
        "issues.#{issue_index}.created_by_user_id"
      )
      |> validate_reference(
        ids.agents,
        field(issue, :last_reviewer_id),
        "issues.#{issue_index}.last_reviewer_id"
      )
      |> validate_issue_label_references(issue, issue_index, ids.labels)
      |> validate_comment_author_references(issue, issue_index, ids.agents, member_user_ids)
    end)
  end

  defp validate_issue_label_references(errors, issue, issue_index, label_ids) do
    labels = collection(issue, :labels)

    errors =
      labels
      |> Enum.with_index()
      |> Enum.reduce(errors, fn {label, label_index}, acc ->
        validate_reference(
          acc,
          label_ids,
          field(label, :id),
          "issues.#{issue_index}.labels.#{label_index}.id",
          required?: true
        )
      end)

    referenced_ids = Enum.map(labels, &field(&1, :id))

    if duplicate_values(referenced_ids) == [] do
      errors
    else
      [
        error(
          "issues.#{issue_index}.labels",
          :duplicate_reference,
          "An issue cannot reference the same label more than once."
        )
        | errors
      ]
    end
  end

  defp validate_comment_author_references(
         errors,
         issue,
         issue_index,
         agent_ids,
         member_user_ids
       ) do
    issue
    |> collection(:comments)
    |> Enum.with_index()
    |> Enum.reduce(errors, fn {comment, comment_index}, acc ->
      path = "issues.#{issue_index}.comments.#{comment_index}.author_id"

      case field(comment, :author_type) do
        author_type when author_type in ["agent", :agent] ->
          validate_reference(acc, agent_ids, field(comment, :author_id), path, required?: true)

        author_type when author_type in ["user", :user] ->
          validate_reference(
            acc,
            member_user_ids,
            field(comment, :author_id),
            path,
            required?: true
          )

        _other ->
          acc
      end
    end)
  end

  defp validate_secret_scope_references(errors, data, ids) do
    data
    |> collection(:secret_manifest)
    |> Enum.with_index()
    |> Enum.reduce(errors, fn {secret, index}, acc ->
      path = "secret_manifest.#{index}.scope_id"

      case field(secret, :scope) do
        scope when scope in ["project", :project] ->
          validate_reference(acc, ids.projects, field(secret, :scope_id), path, required?: true)

        scope when scope in ["agent", :agent] ->
          validate_reference(acc, ids.agents, field(secret, :scope_id), path, required?: true)

        scope when scope in ["company", :company, "instance", :instance] ->
          case field(secret, :scope_id) do
            nil ->
              acc

            _scope_id ->
              [
                error(
                  path,
                  :unexpected_scope_id,
                  "Company and instance secret restore entries cannot carry a source scope ID."
                )
                | acc
              ]
          end

        _scope ->
          [
            error(
              "secret_manifest.#{index}.scope",
              :invalid_secret_scope,
              "Secret restore scope must be company, instance, project, or agent."
            )
            | acc
          ]
      end
    end)
  end

  defp validate_reference(errors, allowed_ids, value, path, opts \\ []) do
    required? = Keyword.get(opts, :required?, false)

    cond do
      is_nil(value) and not required? ->
        errors

      is_binary(value) and value != "" and MapSet.member?(allowed_ids, value) ->
        errors

      true ->
        [
          error(
            path,
            :unmapped_reference,
            "#{path} must reference a record included in this import package."
          )
          | errors
        ]
    end
  end

  defp validate_unredacted_secrets(errors, data) do
    count = count_unredacted_secret_values(data, :package)

    if count == 0 do
      errors
    else
      message =
        "Import package contains #{count} unredacted credential value(s). Remove them and export again."

      [error(:package, :unredacted_secret_values, message) | errors]
    end
  end

  defp build_plan(data, strategy, includes) do
    company = field(data, :company, %{})
    source_slug = field(company, :slug)
    target = slug_plan(source_slug, strategy)
    inventory = inventory(data)
    requirements = secret_restore_requirements(data)

    %{
      format: "cympho-company",
      version: field(data, :version),
      supported_versions: @supported_versions,
      ready?: target.status == :ready,
      company: %{name: field(company, :name), source_slug: source_slug},
      target: target,
      inventory: inventory,
      includes: includes,
      warnings: warnings(target, inventory, requirements),
      secret_restore_requirements: requirements
    }
  end

  defp inventory(data) do
    issues = collection(data, :issues)
    users = collection(data, :users)
    existing_user_count = existing_user_count(users)

    inventory = %{
      companies: 1,
      users: length(users),
      users_to_create: max(length(users) - existing_user_count, 0),
      users_to_reuse: existing_user_count,
      memberships: count(data, :memberships),
      projects: count(data, :projects),
      agents: count(data, :agents),
      issues: length(issues),
      comments: nested_count(issues, :comments),
      issue_label_assignments: nested_count(issues, :labels),
      goals: count(data, :goals),
      labels: count(data, :labels),
      ignored_documents: nested_count(issues, :documents),
      secret_restore_requirements: count(data, :secret_manifest)
    }

    package_records =
      ~w(companies users memberships projects agents issues comments issue_label_assignments goals labels)a
      |> Enum.sum_by(&Map.fetch!(inventory, &1))

    inventory
    |> Map.put(:package_records, package_records)
    |> Map.put(:planned_writes, package_records - existing_user_count)
  end

  defp existing_user_count(users) do
    emails =
      users
      |> Enum.map(&field(&1, :email))
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.uniq()

    case emails do
      [] ->
        0

      values ->
        User
        |> where([user], user.email in ^values)
        |> Repo.aggregate(:count, :id)
    end
  end

  defp slug_plan(source_slug, strategy) do
    collision? = company_slug_exists?(source_slug)

    cond do
      not collision? ->
        target(source_slug, source_slug, strategy, false, :ready, :create)

      strategy == :fail ->
        target(source_slug, source_slug, strategy, true, :blocked, :fail)

      true ->
        target(
          source_slug,
          next_available_slug(source_slug),
          strategy,
          true,
          :ready,
          :create_with_suffix
        )
    end
  end

  defp target(requested_slug, slug, strategy, collision?, status, action) do
    %{
      requested_slug: requested_slug,
      slug: slug,
      strategy: strategy,
      collision?: collision?,
      status: status,
      action: action
    }
  end

  defp next_available_slug(source_slug) do
    Stream.iterate(1, &(&1 + 1))
    |> Enum.find_value(fn number ->
      suffix = if number == 1, do: "-copy", else: "-copy-#{number}"
      candidate = String.slice(source_slug, 0, 50 - String.length(suffix)) <> suffix
      if company_slug_exists?(candidate), do: nil, else: candidate
    end)
  end

  defp company_slug_exists?(slug) when is_binary(slug),
    do: Repo.exists?(from(company in Company, where: company.slug == ^slug))

  defp company_slug_exists?(_slug), do: false

  defp secret_restore_requirements(data) do
    project_ids = ids(data, :projects)
    agent_ids = ids(data, :agents)

    data
    |> collection(:secret_manifest)
    |> Enum.map(fn secret ->
      scope = field(secret, :scope, "company") |> to_string()
      scope_id = field(secret, :scope_id)

      %{
        key: field(secret, :key),
        scope: scope,
        original_scope_id: scope_id,
        will_remap_scope?: scope in ["project", "agent"] and not is_nil(scope_id),
        restore_status: restore_status(scope, scope_id, project_ids, agent_ids)
      }
    end)
  end

  defp restore_status("project", scope_id, project_ids, _agent_ids) when is_binary(scope_id),
    do:
      if(MapSet.member?(project_ids, scope_id),
        do: "requires_value",
        else: "missing_scope_target"
      )

  defp restore_status("agent", scope_id, _project_ids, agent_ids) when is_binary(scope_id),
    do:
      if(MapSet.member?(agent_ids, scope_id), do: "requires_value", else: "missing_scope_target")

  defp restore_status(_scope, _scope_id, _project_ids, _agent_ids), do: "requires_value"

  defp warnings(target, inventory, requirements) do
    []
    |> maybe_warn(
      target.collision? and target.status == :ready,
      :slug_collision_resolved,
      "Company slug #{target.requested_slug} already exists. Import will create #{target.slug}."
    )
    |> maybe_warn(
      target.status == :blocked,
      :slug_collision_blocked,
      "Company slug #{target.requested_slug} already exists and the fail strategy blocks import."
    )
    |> maybe_warn(
      inventory.users_to_reuse > 0,
      :existing_users_reused,
      "#{inventory.users_to_reuse} existing user account(s) will be linked instead of recreated."
    )
    |> maybe_warn(
      inventory.ignored_documents > 0,
      :documents_not_imported,
      "#{inventory.ignored_documents} embedded document record(s) are not imported by V1."
    )
    |> maybe_warn(
      Enum.any?(requirements, &(&1.restore_status == "missing_scope_target")),
      :missing_secret_scope_targets,
      "Some secret restore entries reference project or agent records absent from this package."
    )
  end

  defp maybe_warn(warnings, false, _code, _message), do: warnings

  defp maybe_warn(warnings, true, code, message),
    do: warnings ++ [%{code: code, message: message}]

  defp count_unredacted_secret_values(value, _context) when is_struct(value), do: 0

  defp count_unredacted_secret_values(value, context) when is_map(value) do
    Enum.reduce(value, 0, fn {key, nested}, total ->
      nested_context =
        if normalize_field(key) == "secret_manifest", do: :secret_manifest, else: context

      if secret_field?(key, context) do
        total + if(nested in [nil, "", @redacted_secret_marker], do: 0, else: 1)
      else
        total + count_unredacted_secret_values(nested, nested_context)
      end
    end)
  end

  defp count_unredacted_secret_values(value, context) when is_list(value),
    do: Enum.sum(Enum.map(value, &count_unredacted_secret_values(&1, context)))

  defp count_unredacted_secret_values(_value, _context), do: 0

  defp secret_field?(key, :secret_manifest) do
    normalized = normalize_field(key)

    normalized != "key" and
      (secret_field?(key) or normalized == "value" or
         String.ends_with?(normalized, "_hash") or
         String.starts_with?(normalized, "encrypted_") or
         String.ends_with?(normalized, "_encrypted") or
         String.starts_with?(normalized, "auth_") or
         String.ends_with?(normalized, "_auth"))
  end

  defp secret_field?(key, _context), do: secret_field?(key)

  defp secret_field?(key) do
    normalized = normalize_field(key)

    normalized in @secret_fields or
      Enum.any?(@secret_field_suffixes, &String.ends_with?(normalized, &1))
  end

  defp normalize_field(key) do
    key
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "_")
    |> String.trim("_")
  end

  defp ids(data, key) do
    data
    |> collection(key)
    |> Enum.map(&field(&1, :id))
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp count(data, key), do: data |> collection(key) |> length()

  defp nested_count(records, key) do
    Enum.sum(Enum.map(records, fn record -> record |> collection(key) |> length() end))
  end

  defp collection(data, key) do
    case field(data, key, []) do
      records when is_list(records) -> records
      _other -> []
    end
  end

  defp field(map, key, default \\ nil)

  defp field(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, to_string(key), default))

  defp field(_map, _key, default), do: default

  defp format_changeset_error({message, opts}) do
    Enum.reduce(opts, message, fn {key, value}, formatted ->
      String.replace(formatted, "%{#{key}}", to_string(value))
    end)
  end

  defp error(field_name, code, message),
    do: %{field: to_string(field_name), code: code, message: message}
end
