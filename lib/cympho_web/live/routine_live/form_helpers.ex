defmodule CymphoWeb.RoutineLive.FormHelpers do
  @moduledoc false

  use CymphoWeb, :html

  alias Cympho.{Agents, Projects}
  alias Cympho.Agents.Agent

  attr :form, :any, required: true
  attr :agent_options, :list, required: true
  attr :project_options, :list, required: true
  attr :effect, :string, required: true, doc: "what saving does, one sentence"
  attr :submit, :string, required: true
  attr :cancel, :string, required: true, doc: "where Cancel goes"

  @doc "The repeating-task form shared by New and Edit (v7 L13/L15)."
  def routine_form(assigns) do
    ~H"""
    <.form_pair id="routine-form" for={@form} phx-submit="save" heading="After you save" verb="save">
      <.band_card id="rf-what-t" title="What it does">
        <div class="flds">
          <.input
            field={@form[:name]}
            label="Name"
            required
            placeholder="Weekly release readiness"
            wrapper_class="full"
          />
          <.input
            field={@form[:description]}
            label="Run brief"
            type="textarea"
            rows={5}
            placeholder="What each run should check, and what it should report back."
            help="Each run files a task with this brief."
            wrapper_class="full"
          />
          <.input
            type="select"
            field={@form[:agent_id]}
            label="Default owner"
            value={@form[:agent_id].value || ""}
            options={@agent_options}
          />
          <.input
            type="select"
            field={@form[:project_id]}
            label="Project"
            value={@form[:project_id].value || ""}
            options={@project_options}
          />
          <.input
            type="select"
            field={@form[:priority]}
            label="Priority"
            value={@form[:priority].value || :medium}
            options={[
              {"Critical", "critical"},
              {"High", "high"},
              {"Medium", "medium"},
              {"Low", "low"}
            ]}
          />
        </div>
      </.band_card>

      <.band_card id="rf-run-t" title="How it runs" class="ui-advanced-only">
        <div class="flds">
          <.input
            type="select"
            field={@form[:concurrency_policy]}
            label="When a run is still going"
            value={@form[:concurrency_policy].value || :coalesce_if_active}
            options={[
              {"Combine overlapping runs", "coalesce_if_active"},
              {"Skip if active", "skip_if_active"},
              {"Always enqueue", "always_enqueue"}
            ]}
          />
          <.input
            type="select"
            field={@form[:catch_up_policy]}
            label="Missed run handling"
            value={@form[:catch_up_policy].value || :skip_missed}
            options={[
              {"Skip missed", "skip_missed"},
              {"Enqueue missed with cap", "enqueue_missed_with_cap"}
            ]}
          />
          <.input
            type="number"
            field={@form[:catch_up_cap]}
            label="Maximum missed runs"
            value={@form[:catch_up_cap].value || 5}
            min="1"
          />
        </div>
      </.band_card>

      <:effect>
        <.consequences rows={[{:done, @effect}]} />
      </:effect>
      <:secondary>
        <.ghost_pill navigate={@cancel}>Cancel</.ghost_pill>
      </:secondary>
      <:primary>
        <.primary_pill type="submit" phx-disable-with="Saving…">{@submit}</.primary_pill>
      </:primary>
    </.form_pair>
    """
  end

  def assign_context_options(socket) do
    company_id = current_company_id(socket)

    socket
    |> assign(:agent_options, agent_options(company_id))
    |> assign(:project_options, project_options(company_id))
  end

  def scoped_routine_params(socket, params, opts \\ []) do
    company_id = current_company_id(socket)

    if is_binary(company_id) do
      with :ok <- validate_agent_ref(company_id, params["agent_id"]),
           :ok <- validate_project_ref(company_id, params["project_id"]) do
        {:ok, maybe_put_company_scope(company_id, params, Keyword.get(opts, :put_company_scope))}
      end
    else
      {:error, :not_found}
    end
  end

  defp maybe_put_company_scope(nil, params, _put_scope?), do: params
  defp maybe_put_company_scope(_company_id, params, false), do: params

  defp maybe_put_company_scope(company_id, params, _put_scope?),
    do: Map.put(params, "company_id", company_id)

  defp validate_agent_ref(_company_id, nil), do: :ok
  defp validate_agent_ref(_company_id, ""), do: :ok

  defp validate_agent_ref(company_id, agent_id) when is_binary(company_id) do
    case Agents.get_company_agent(company_id, agent_id) do
      {:ok, _agent} -> :ok
      {:error, _} -> {:error, :not_found}
    end
  end

  defp validate_agent_ref(_company_id, _agent_id), do: {:error, :not_found}

  defp validate_project_ref(_company_id, nil), do: :ok
  defp validate_project_ref(_company_id, ""), do: :ok

  defp validate_project_ref(company_id, project_id) when is_binary(company_id) do
    case Projects.get_company_project(company_id, project_id) do
      {:ok, _project} -> :ok
      {:error, _} -> {:error, :not_found}
    end
  end

  defp validate_project_ref(_company_id, _project_id), do: {:error, :not_found}

  defp agent_options(nil), do: [{"No default owner", ""}]

  defp agent_options(company_id) do
    options =
      company_id
      |> Agents.list_agents_by_company()
      |> Enum.reject(&(&1.governance_status == "terminated"))
      |> Enum.map(&{agent_option_label(&1), &1.id})

    [{"No default owner", ""} | options]
  end

  defp project_options(nil), do: [{"No project context", ""}]

  defp project_options(company_id) do
    options =
      company_id
      |> Projects.list_projects_by_company()
      |> Enum.reject(&(&1.status == :archived))
      |> Enum.map(&{&1.name, &1.id})

    [{"No project context", ""} | options]
  end

  defp agent_option_label(%{name: name, role: role}) do
    "#{name} · #{Agent.role_label(role)}"
  end

  defp current_company_id(%{assigns: %{current_company: %{id: id}}}), do: id
  defp current_company_id(_socket), do: nil

  # ── Schedule presentation (shared by index + show; presentation-only) ──────

  @doc """
  Human-readable schedule for a routine's triggers.

  Prefers the first enabled schedule trigger and renders its cron in plain
  language; otherwise reports the webhook / disabled / no-trigger state so a
  card can answer "when does this run?" at a glance.
  """
  def schedule_summary(triggers) when is_list(triggers) do
    enabled = Enum.filter(triggers, & &1.enabled)

    cond do
      triggers == [] -> "No trigger yet"
      enabled == [] -> "Triggers paused"
      true -> summarize_enabled(enabled)
    end
  end

  def schedule_summary(_), do: "No trigger yet"

  defp summarize_enabled(enabled) do
    case Enum.find(enabled, &(&1.type == "schedule" and is_binary(&1.cron_expression))) do
      %{cron_expression: expr} ->
        humanize_cron(expr)

      _ ->
        if Enum.any?(enabled, &(&1.type == "webhook")), do: "Runs on webhook", else: "Scheduled"
    end
  end

  @doc "Raw cron expression of the first enabled schedule trigger, or nil (for advanced/tooltip)."
  def raw_cron(triggers) when is_list(triggers) do
    case Enum.find(triggers, &(&1.type == "schedule" and is_binary(&1.cron_expression))) do
      %{cron_expression: expr} -> expr
      _ -> nil
    end
  end

  def raw_cron(_), do: nil

  @doc "Humane next-run label from a routine's triggers, or nil when event-driven/none."
  def next_run(triggers) when is_list(triggers) do
    enabled = Enum.filter(triggers, & &1.enabled)

    case Enum.find(enabled, &(&1.type == "schedule" and is_binary(&1.cron_expression))) do
      %{cron_expression: expr} ->
        next_run_from_cron(expr)

      _ ->
        if Enum.any?(enabled, &(&1.type == "webhook")), do: "on event", else: nil
    end
  end

  def next_run(_), do: nil

  defp next_run_from_cron(expr) do
    with {:ok, cron} <- Crontab.CronExpression.Parser.parse(expr),
         {:ok, naive} <- Crontab.Scheduler.get_next_run_date(cron, NaiveDateTime.utc_now()) do
      humanize_relative(naive)
    else
      _ -> nil
    end
  end

  defp humanize_relative(%NaiveDateTime{} = naive) do
    secs = NaiveDateTime.diff(naive, NaiveDateTime.utc_now())

    cond do
      secs <= 0 -> "due now"
      secs < 60 -> "in under a minute"
      secs < 3_600 -> "in #{div(secs, 60)}m"
      secs < 86_400 -> "in #{div(secs, 3_600)}h"
      secs < 2_592_000 -> "in #{div(secs, 86_400)}d"
      true -> "in #{div(secs, 2_592_000)}mo"
    end
  end

  @doc """
  Plain-language rendering of a 5-field cron expression.

  Covers the common cadences and falls back to the raw expression for anything
  it does not recognise, so the string is always safe to show.
  """
  def humanize_cron(expr) when is_binary(expr) do
    case String.split(String.trim(expr), ~r/\s+/, trim: true) do
      [m, h, dom, month, dow] -> describe_cron(expr, m, h, dom, month, dow)
      _ -> expr
    end
  end

  def humanize_cron(_), do: "Custom schedule"

  defp describe_cron(_e, "*", "*", "*", "*", "*"), do: "Every minute"
  defp describe_cron(_e, "*/" <> n, "*", "*", "*", "*"), do: "Every #{n} minutes"
  defp describe_cron(_e, "0", "*", "*", "*", "*"), do: "Hourly, on the hour"

  defp describe_cron(e, m, "*", "*", "*", "*") do
    case cron_int(m) do
      nil -> e
      min -> "Hourly at :#{pad(min)}"
    end
  end

  defp describe_cron(e, m, h, dom, month, dow) do
    case {cron_int(m), cron_int(h)} do
      {min, hr} when is_integer(min) and is_integer(hr) ->
        time = "#{pad(hr)}:#{pad(min)}"

        cond do
          {dom, month, dow} == {"*", "*", "*"} -> "Daily at #{time}"
          month == "*" and dom == "*" and cron_day(dow) -> "Weekly on #{cron_day(dow)} at #{time}"
          month == "*" and dow == "*" and cron_int(dom) -> "Monthly on day #{dom} at #{time}"
          true -> e
        end

      _ ->
        e
    end
  end

  defp cron_int(str) do
    case Integer.parse(str) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp pad(n), do: String.pad_leading(Integer.to_string(n), 2, "0")

  defp cron_day(d) when d in ["0", "7"], do: "Sunday"
  defp cron_day("1"), do: "Monday"
  defp cron_day("2"), do: "Tuesday"
  defp cron_day("3"), do: "Wednesday"
  defp cron_day("4"), do: "Thursday"
  defp cron_day("5"), do: "Friday"
  defp cron_day("6"), do: "Saturday"
  defp cron_day(_), do: nil

  @doc "A run's status as a glyph kind and a word (v7 §1.5)."
  def run_state(status) when status in ["running", :running], do: {:working, "Working"}

  def run_state(status) when status in ["completed", "succeeded", "success", :completed],
    do: {:done, "Finished"}

  def run_state(status) when status in ["failed", "error", :failed], do: {:stopped, "Failed"}
  def run_state(status) when status in ["timed_out", :timed_out], do: {:stopped, "Timed out"}

  def run_state(status) when status in ["pending", "queued", :pending],
    do: {:idle, "Waiting to start"}

  def run_state(status),
    do: {:idle, status |> to_string() |> String.replace("_", " ") |> String.capitalize()}
end
