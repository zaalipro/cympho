defmodule Cympho.Onboarding do
  @moduledoc """
  Persists resumable onboarding drafts and creates scoped improvement work.

  Draft persistence is intentionally allowlisted. Simple executable commands
  and model names may resume, but credential-bearing values, tokens, passwords,
  secrets, arbitrary command strings, and unknown fields never reach the database.
  """

  import Ecto.Query, warn: false

  alias Cympho.CompanyRBAC
  alias Cympho.Goals
  alias Cympho.Goals.Goal
  alias Cympho.Issues
  alias Cympho.Issues.Issue
  alias Cympho.Projects
  alias Cympho.Repo
  alias Cympho.Users.User

  @safe_form_fields ~w(
    blueprint
    name
    goal_title
    improvement_details
    project_name
    issue_prefix
    engineer_count
    engineer_names
    adapter
    runtime_model
    runtime_command
    role_overrides
    role_runtimes
  )
  @paths ~w(start improve)
  @allowed_adapters ~w(claude_code codex cursor http)
  @max_step 3
  @max_text_length 2_000

  @secret_patterns [
    ~r/\bsk-[A-Za-z0-9_-]{8,}\b/i,
    ~r/\bbearer\s+[A-Za-z0-9._~+\/-]{12,}/i,
    ~r/\b(?:api[_ -]?key|access[_ -]?token|auth[_ -]?token|token|password|secret)\s*[:=]/i,
    ~r/\b(?:AKIA|ASIA)[A-Z0-9]{16}\b/,
    ~r/\b(?:gh[pousr]_|github_pat_)[A-Za-z0-9_]{20,}\b/i,
    ~r/\bxox[baprs]-[A-Za-z0-9-]{10,}\b/i,
    ~r/\bAIza[A-Za-z0-9_-]{20,}\b/,
    ~r/\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b/,
    ~r/-----BEGIN [A-Z ]*PRIVATE KEY-----/i
  ]

  def get_draft(user_id) when is_binary(user_id) do
    case Repo.get(User, user_id) do
      %User{onboarding_draft: draft} when is_map(draft) -> sanitize_draft(draft)
      _ -> %{}
    end
  end

  def get_draft(_user_id), do: %{}

  def get_draft(user_id, company_id) do
    case get_draft(user_id) do
      %{"path" => "improve", "company_id" => draft_company_id} = draft
      when draft_company_id == company_id ->
        draft

      %{"path" => "improve"} ->
        %{}

      draft ->
        draft
    end
  end

  def save_draft(user_id, attrs) when is_binary(user_id) and is_map(attrs) do
    case Repo.get(User, user_id) do
      nil ->
        {:error, :not_found}

      user ->
        user
        |> Ecto.Changeset.change(onboarding_draft: sanitize_draft(attrs))
        |> Repo.update()
    end
  end

  def save_draft(_user_id, _attrs), do: {:error, :invalid_draft}

  def clear_draft(user_id) when is_binary(user_id) do
    case Repo.get(User, user_id) do
      nil -> {:error, :not_found}
      user -> user |> Ecto.Changeset.change(onboarding_draft: %{}) |> Repo.update()
    end
  end

  def clear_draft(_user_id), do: {:error, :not_found}

  @doc false
  def sanitize_draft(attrs) when is_map(attrs) do
    path = field(attrs, "path")
    form = field(attrs, "form", %{})

    %{}
    |> maybe_put("path", if(path in @paths, do: path))
    |> maybe_put("current_step", sanitize_step(field(attrs, "current_step")))
    |> maybe_put("company_id", sanitize_company_id(field(attrs, "company_id")))
    |> maybe_put("submission_id", sanitize_submission_id(field(attrs, "submission_id")))
    |> maybe_put("form", sanitize_form(form))
  end

  def sanitize_draft(_attrs), do: %{}

  def create_improvement(company_id, user_id, attrs)
      when is_binary(company_id) and is_binary(user_id) and is_map(attrs) do
    title = attrs |> field("goal_title", "") |> normalize_text(255)
    details = attrs |> field("improvement_details", "") |> normalize_text(@max_text_length)
    submission_id = attrs |> field("submission_id") |> sanitize_submission_id()

    cond do
      not improvement_authorized?(user_id, company_id) ->
        {:error, :forbidden}

      title == "" ->
        {:error, :goal_required}

      unsafe_text?(title) or unsafe_text?(details) ->
        {:error, :sensitive_content}

      true ->
        create_improvement_transaction(
          company_id,
          user_id,
          title,
          details,
          submission_id || Ecto.UUID.generate()
        )
    end
  end

  def create_improvement(_company_id, _user_id, _attrs), do: {:error, :invalid_context}

  defp create_improvement_transaction(company_id, user_id, title, details, submission_id) do
    description = improvement_description(title, details)

    Repo.transaction(fn ->
      user =
        Repo.one!(
          from user in User,
            where: user.id == ^user_id,
            lock: "FOR UPDATE"
        )

      unless improvement_authorized?(user_id, company_id), do: Repo.rollback(:forbidden)

      result =
        case existing_improvement(company_id, user_id, submission_id) do
          %Issue{goal: %Goal{} = goal} = issue ->
            %{goal: goal, issue: issue}

          nil ->
            create_improvement_records(
              company_id,
              user_id,
              title,
              details,
              description,
              submission_id
            )
        end

      clear_matching_draft(user, company_id, submission_id)
      result
    end)
  end

  defp existing_improvement(company_id, user_id, submission_id) do
    Repo.one(
      from issue in Issue,
        where:
          issue.company_id == ^company_id and issue.created_by_user_id == ^user_id and
            issue.origin_type == "onboarding_improvement" and
            issue.origin_id == ^submission_id,
        preload: [:goal]
    )
  end

  defp create_improvement_records(
         company_id,
         user_id,
         title,
         details,
         description,
         submission_id
       ) do
    project = company_id |> Projects.list_projects_by_company() |> List.first()

    goal =
      case Goals.create_goal(%{
             company_id: company_id,
             project_id: project && project.id,
             title: title,
             description:
               if(details == "", do: "Owner-created company improvement.", else: details),
             priority: "high",
             status: "active"
           }) do
        {:ok, goal} -> goal
        {:error, reason} -> Repo.rollback(reason)
      end

    issue =
      case Issues.create_issue(%{
             company_id: company_id,
             project_id: project && project.id,
             goal_id: goal.id,
             title: title,
             description: description,
             status: :todo,
             priority: :high,
             assigned_role: "ceo",
             created_by_user_id: user_id,
             origin_type: "onboarding_improvement",
             origin_id: submission_id
           }) do
        {:ok, issue} -> issue
        {:error, reason} -> Repo.rollback(reason)
      end

    %{goal: goal, issue: issue}
  end

  defp clear_matching_draft(user, company_id, submission_id) do
    draft = sanitize_draft(user.onboarding_draft || %{})

    if draft["company_id"] == company_id and draft["submission_id"] == submission_id do
      user
      |> Ecto.Changeset.change(onboarding_draft: %{})
      |> Repo.update!()
    end

    :ok
  end

  defp improvement_description(title, "") do
    """
    Goal: #{title}

    Context: The owner created this improvement from guided setup.
    Definition of done: The CEO turns this goal into scoped work with clear evidence and a review decision.
    Evidence: Record the plan, implementation artifacts, and verification on this issue.
    """
  end

  defp improvement_description(title, details) do
    """
    Goal: #{title}

    Context: #{details}
    Definition of done: The CEO turns this goal into scoped work with clear evidence and a review decision.
    Evidence: Record the plan, implementation artifacts, and verification on this issue.
    """
  end

  defp sanitize_form(form) when is_map(form) do
    @safe_form_fields
    |> Enum.reduce(%{}, fn key, safe ->
      case sanitize_form_value(key, field(form, key)) do
        nil -> safe
        value when value == %{} -> safe
        value -> Map.put(safe, key, value)
      end
    end)
  end

  defp sanitize_form(_form), do: %{}

  defp sanitize_form_value("engineer_names", names) when is_list(names) do
    names
    |> Enum.take(8)
    |> Enum.map(&normalize_text(&1, 120))
    |> Enum.reject(&(&1 == "" or unsafe_text?(&1)))
  end

  defp sanitize_form_value("engineer_count", value) do
    case Integer.parse(to_string(value || "")) do
      {count, ""} -> to_string(count |> max(0) |> min(8))
      _ -> nil
    end
  end

  defp sanitize_form_value("adapter", adapter) when adapter in @allowed_adapters, do: adapter

  defp sanitize_form_value("runtime_command", command) when is_binary(command) do
    command = String.trim(command)

    if Regex.match?(~r/^[A-Za-z0-9._\/-]{1,120}$/, command) and not unsafe_text?(command),
      do: command
  end

  defp sanitize_form_value("role_overrides", value) when is_boolean(value), do: value

  defp sanitize_form_value("role_runtimes", runtimes) when is_map(runtimes) do
    ["ceo", "cto", "engineer"]
    |> Enum.reduce(%{}, fn role, safe ->
      runtime = field(runtimes, role, %{})

      if is_map(runtime) do
        sanitized =
          %{}
          |> maybe_put("adapter", sanitize_role_adapter(field(runtime, "adapter")))
          |> maybe_put("model", sanitize_form_value("runtime_model", field(runtime, "model")))
          |> maybe_put(
            "command",
            sanitize_form_value("runtime_command", field(runtime, "command"))
          )

        if sanitized == %{}, do: safe, else: Map.put(safe, role, sanitized)
      else
        safe
      end
    end)
  end

  defp sanitize_form_value("issue_prefix", value) do
    value = normalize_text(value, 7)
    if value != "" and not unsafe_text?(value), do: value
  end

  defp sanitize_form_value(_key, value) when is_binary(value) do
    value = normalize_text(value, @max_text_length)
    if value != "" and not unsafe_text?(value), do: value
  end

  defp sanitize_form_value(_key, _value), do: nil

  defp sanitize_step(step) when is_integer(step), do: step |> max(0) |> min(@max_step)

  defp sanitize_step(step) when is_binary(step) do
    case Integer.parse(step) do
      {value, ""} -> sanitize_step(value)
      _ -> nil
    end
  end

  defp sanitize_step(_step), do: nil

  defp sanitize_submission_id(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, submission_id} -> submission_id
      :error -> nil
    end
  end

  defp sanitize_submission_id(_value), do: nil

  defp sanitize_company_id(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, company_id} -> company_id
      :error -> nil
    end
  end

  defp sanitize_company_id(_value), do: nil

  defp normalize_text(value, max_length) when is_binary(value) do
    value |> String.trim() |> String.slice(0, max_length)
  end

  defp normalize_text(_value, _max_length), do: ""

  defp unsafe_text?(""), do: false
  defp unsafe_text?(text), do: Enum.any?(@secret_patterns, &Regex.match?(&1, text))

  defp sanitize_role_adapter(adapter) when adapter in ["" | @allowed_adapters], do: adapter
  defp sanitize_role_adapter(_adapter), do: nil

  defp improvement_authorized?(user_id, company_id) do
    CompanyRBAC.manager?(user_id, company_id)
  end

  defp field(map, key, default \\ nil) when is_map(map) do
    Map.get(map, key, Map.get(map, String.to_existing_atom(key), default))
  rescue
    ArgumentError -> Map.get(map, key, default)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, value) when value == %{}, do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
