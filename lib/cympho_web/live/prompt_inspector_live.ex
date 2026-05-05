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
    case Issues.get_issue(issue_id) do
      {:ok, issue} ->
        prompt = AgentPrompt.build(issue, agent_id)
        assign(socket, prompt: prompt, error: nil)

      {:error, _} ->
        assign(socket, prompt: nil, error: "Issue not found.")
    end
  rescue
    e ->
      assign(socket, prompt: nil, error: "Build failed: #{Exception.message(e)}")
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

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

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-6 max-w-5xl mx-auto space-y-4">
      <h1 class="text-xl font-semibold">Prompt inspector</h1>
      <p class="text-sm text-text-secondary">
        Renders the exact prompt <code>AgentPrompt.build/3</code>
        sends to the runtime adapter for the selected (issue, agent) pair. Dev only.
      </p>

      <form phx-change="preview" class="grid grid-cols-1 md:grid-cols-2 gap-3">
        <label class="flex flex-col gap-1">
          <span class="text-xs text-text-secondary uppercase tracking-wide">Agent</span>
          <select name="agent_id" class="rounded border border-hairline bg-panel p-2 text-sm">
            <option value="">— No agent (issue context only) —</option>
            <option :for={{label, id} <- @agents} value={id} selected={@agent_id == id}>
              {label}
            </option>
          </select>
        </label>

        <label class="flex flex-col gap-1">
          <span class="text-xs text-text-secondary uppercase tracking-wide">Issue</span>
          <select name="issue_id" class="rounded border border-hairline bg-panel p-2 text-sm">
            <option value="">— Pick an issue —</option>
            <option :for={{label, id} <- @issues} value={id} selected={@issue_id == id}>
              {label}
            </option>
          </select>
        </label>
      </form>

      <div :if={@error} class="text-sm text-red-400">{@error}</div>

      <pre
        :if={@prompt}
        class="rounded border border-hairline bg-panel p-4 text-xs whitespace-pre-wrap leading-relaxed overflow-auto max-h-[70vh]"
      >{@prompt}</pre>
    </div>
    """
  end
end
