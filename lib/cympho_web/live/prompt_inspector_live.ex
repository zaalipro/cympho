defmodule CymphoWeb.PromptInspectorLive do
  @moduledoc """
  Dev-only tool: pick an agent and an issue, render the actual prompt that
  `Cympho.AgentPrompt.build/3` produces. Read-only, no side effects.

  Mounted in router.ex only when `Mix.env() == :dev`.
  """

  use CymphoWeb, :live_view

  alias Cympho.{AgentPrompt, Agents, Issues}

  @impl true
  def mount(_params, _session, socket) do
    company = socket.assigns[:current_company]
    company_id = company && company.id

    {:ok,
     socket
     |> assign(:page_title, "Prompt inspector")
     |> assign(:agents, list_agents(company_id))
     |> assign(:issues, list_issues(company_id))
     |> assign(:agent_id, nil)
     |> assign(:issue_id, nil)
     |> assign(:prompt, nil)
     |> assign(:error, nil)}
  end

  @impl true
  def handle_event("preview", %{"agent_id" => agent_id, "issue_id" => issue_id}, socket) do
    socket =
      socket
      |> assign(:agent_id, blank_to_nil(agent_id))
      |> assign(:issue_id, blank_to_nil(issue_id))
      |> render_prompt()

    {:noreply, socket}
  end

  defp render_prompt(%{assigns: %{issue_id: nil}} = socket) do
    assign(socket, prompt: nil, error: "Pick an issue first.")
  end

  defp render_prompt(%{assigns: %{issue_id: issue_id, agent_id: agent_id}} = socket) do
    with {:ok, issue} <- get_scoped_issue(socket, issue_id),
         :ok <- validate_scoped_agent(socket, agent_id) do
      prompt = AgentPrompt.build(issue, agent_id)
      assign(socket, prompt: prompt, error: nil)
    else
      {:error, _} ->
        assign(socket, prompt: nil, error: "Issue not found.")
    end
  rescue
    e ->
      assign(socket, prompt: nil, error: "Build failed: #{Exception.message(e)}")
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp get_scoped_issue(socket, issue_id) do
    case socket.assigns[:current_company] do
      %{id: company_id} -> Issues.get_company_issue(company_id, issue_id)
      _ -> Issues.get_issue(issue_id)
    end
  end

  defp validate_scoped_agent(_socket, nil), do: :ok

  defp validate_scoped_agent(socket, agent_id) do
    case socket.assigns[:current_company] do
      %{id: company_id} ->
        case Agents.get_company_agent(company_id, agent_id) do
          {:ok, _agent} -> :ok
          {:error, _} -> {:error, :not_found}
        end

      _ ->
        :ok
    end
  end

  defp list_agents(nil), do: []

  defp list_agents(company_id) do
    company_id
    |> Agents.list_agents_by_company()
    |> Enum.map(fn a -> {"#{a.name} · #{a.role}", a.id} end)
  end

  defp list_issues(nil), do: []

  defp list_issues(company_id) do
    %{company_id: company_id}
    |> Issues.list_issues()
    |> Enum.take(100)
    |> Enum.map(fn i ->
      label = "#{i.identifier || String.slice(i.id, 0, 8)} · #{i.title} (#{i.status})"
      {label, i.id}
    end)
  rescue
    _ -> []
  end

  defp prompt_stats(nil) do
    %{chars: 0, sections: 0, action_contract?: false, owner_revision?: false, digest?: false}
  end

  defp prompt_stats(prompt) when is_binary(prompt) do
    %{
      chars: String.length(prompt),
      sections: prompt |> String.split("\n") |> Enum.count(&String.starts_with?(&1, "## ")),
      action_contract?: String.contains?(prompt, "## Required response contract"),
      owner_revision?: String.contains?(prompt, "## Owner revision request"),
      digest?: String.contains?(prompt, "## Digest quality checklist")
    }
  end

  defp signal_class(true), do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"
  defp signal_class(false), do: "border-border bg-surface text-text-tertiary"

  @impl true
  def render(assigns) do
    ~H"""
    <% stats = prompt_stats(@prompt) %>
    <.page size="content">
      <div class="mb-4 flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <h1 class="text-2xl font-590 tracking-tight text-text-primary">Prompt Inspector</h1>
          <p class="mt-1 text-sm text-text-tertiary">Dev runtime prompt preview</p>
        </div>
        <div class="flex flex-wrap items-center gap-2">
          <span class="rounded-full border border-border bg-surface px-2.5 py-1 text-xs font-510 text-text-tertiary">
            {stats.sections} sections
          </span>
          <span class="rounded-full border border-border bg-surface px-2.5 py-1 text-xs font-510 text-text-tertiary">
            {stats.chars} chars
          </span>
        </div>
      </div>

      <.panel class="overflow-hidden">
        <form phx-change="preview" class="grid gap-4 p-5 md:grid-cols-2">
          <label class="flex min-w-0 flex-col gap-1.5">
            <span class="text-[11px] font-590 uppercase tracking-[0.08em] text-text-quaternary">
              Agent
            </span>
            <.select_menu
              name="agent_id"
              value={@agent_id || ""}
              options={[{"No agent (issue context only)", ""} | @agents]}
            />
          </label>

          <label class="flex min-w-0 flex-col gap-1.5">
            <span class="text-[11px] font-590 uppercase tracking-[0.08em] text-text-quaternary">
              Issue
            </span>
            <.select_menu
              name="issue_id"
              value={@issue_id || ""}
              options={[{"Pick an issue", ""} | @issues]}
            />
          </label>
        </form>

        <div
          :if={@error}
          class="border-t border-border bg-brand/[0.06] px-5 py-3 text-sm text-brand"
        >
          {@error}
        </div>
      </.panel>

      <div :if={@prompt} class="mt-4 grid gap-4 lg:grid-cols-[220px_minmax(0,1fr)]">
        <.panel class="h-fit p-4">
          <h2 class="text-sm font-590 text-text-primary">Prompt Signals</h2>
          <div class="mt-3 grid gap-2">
            <span class={"rounded-full border px-2.5 py-1 text-xs font-510 #{signal_class(stats.action_contract?)}"}>
              Action contract
            </span>
            <span class={"rounded-full border px-2.5 py-1 text-xs font-510 #{signal_class(stats.digest?)}"}>
              Digest checklist
            </span>
            <span class={"rounded-full border px-2.5 py-1 text-xs font-510 #{signal_class(stats.owner_revision?)}"}>
              Owner revision
            </span>
          </div>
        </.panel>

        <.panel class="overflow-hidden">
          <div
            id="prompt-inspector-copy"
            phx-hook="CopyToClipboard"
            class="flex items-center justify-between gap-3 border-b border-border px-4 py-3"
          >
            <h2 class="text-sm font-590 text-text-primary">Generated Prompt</h2>
            <button
              type="button"
              data-copy-text={@prompt}
              data-copy-label="Copy prompt"
              data-copy-success-label="Copied"
              class="rounded-md border border-border bg-surface px-2.5 py-1.5 text-xs font-510 text-text-secondary hover:border-border-hover hover:bg-surface-hover hover:text-text-primary"
            >
              Copy prompt
            </button>
          </div>
          <pre class="max-h-[70vh] overflow-auto whitespace-pre-wrap p-4 font-mono text-xs leading-6 text-text-secondary">{@prompt}</pre>
        </.panel>
      </div>
    </.page>
    """
  end
end
