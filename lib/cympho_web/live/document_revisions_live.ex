defmodule CymphoWeb.DocumentRevisionsLive do
  use CymphoWeb, :live_component

  @doc """
  Renders a list of revisions for a document.
  """
  def render(assigns) do
    ~H"""
    <div class="space-y-4">
      <.history_header
        document={@document}
        revisions_count={length(@revisions)}
        on_close={@on_close}
      />

      <.revisions_list
        revisions={@revisions}
        current_revision_id={@current_revision_id}
        document={@document}
        on_view_diff={@on_view_diff}
        on_rollback={@on_rollback}
      />

      <.diff_modal
        id="revision-diff-modal"
        show={@show_diff_modal}
        diff={@diff}
        on_close={@hide_diff_modal}
      />

      <.rollback_modal
        id="rollback-confirmation-modal"
        show={@show_rollback_modal}
        revision={@rollback_revision}
        document={@document}
        on_confirm={@confirm_rollback}
        on_close={@hide_rollback_modal}
      />
    </div>
    """
  end

  def history_header(assigns) do
    ~H"""
    <div class="flex items-center justify-between mb-4">
      <div>
        <h3 class="text-lg font-semibold text-text-primary">Document History</h3>
        <p class="text-sm text-text-tertiary mt-1">
          {@revisions_count} revision{if @revisions_count != 1, do: "s"}
        </p>
      </div>
      <button
        type="button"
        phx-click={@on_close}
        class="text-text-quaternary hover:text-text-secondary transition-colors"
        aria-label="Close"
      >
        <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M6 18L18 6M6 6l12 12"
          />
        </svg>
      </button>
    </div>
    """
  end

  def revisions_list(assigns) do
    ~H"""
    <div class="space-y-2 max-h-96 overflow-y-auto">
      <div
        :for={revision <- @revisions}
        id={"revision-#{revision.id}"}
        class="flex items-start gap-3 p-3 rounded-md bg-white/[0.02] border border-border hover:bg-white/[0.04] transition-colors"
      >
        <div class="flex-shrink-0">
          <div class="w-8 h-8 rounded-full bg-blue-500/20 text-blue-400 flex items-center justify-center text-xs font-semibold">
            {String.first(revision.author_type || "A")}
          </div>
        </div>

        <div class="flex-1 min-w-0">
          <div class="flex items-center gap-2 mb-1">
            <span class="text-sm font-medium text-text-primary">
              Revision #{revision.revision_number}
            </span>
            <span
              :if={is_current_revision?(revision, @current_revision_id)}
              class="text-xs px-2 py-0.5 rounded-full bg-green-500/20 text-green-400"
            >
              Current
            </span>
          </div>

          <p class="text-sm font-medium text-text-primary mb-1">{revision.title}</p>

          <p :if={revision.change_summary} class="text-xs text-text-tertiary mb-2">
            {revision.change_summary}
          </p>

          <p class="text-xs text-text-quaternary">
            {format_timestamp(revision.inserted_at)}
          </p>
        </div>

        <div class="flex-shrink-0 flex items-center gap-2">
          <button
            type="button"
            phx-click="view_diff"
            phx-value-revision_id={revision.id}
            phx-target={@myself}
            class="text-xs px-3 py-1.5 rounded-md bg-white/[0.05] hover:bg-white/[0.1] text-text-secondary transition-colors"
          >
            Compare
          </button>

          <button
            type="button"
            phx-click="prompt_rollback"
            phx-value-revision_id={revision.id}
            phx-target={@myself}
            class="text-xs px-3 py-1.5 rounded-md bg-white/[0.05] hover:bg-white/[0.1] text-text-secondary transition-colors"
            disabled={is_current_revision?(revision, @current_revision_id)}
          >
            Rollback
          </button>
        </div>
      </div>
    </div>
    """
  end

  def diff_modal(assigns) do
    ~H"""
    <.modal id={@id} show={@show} on_cancel={@on_close} title="Compare Revisions">
      <.diff_content diff={@diff} />
    </.modal>
    """
  end

  def rollback_modal(assigns) do
    ~H"""
    <.modal id={@id} show={@show} on_cancel={@on_close} title="Confirm Rollback">
      <div class="space-y-4">
        <p class="text-sm text-text-secondary">
          Are you sure you want to rollback to revision {@revision.revision_number}? This will create a new revision with the content from that revision.
        </p>

        <div class="bg-white/[0.02] rounded-md p-3 border border-border">
          <p class="text-sm font-medium text-text-primary mb-2">{@revision.title}</p>
          <p class="text-xs text-text-tertiary">{@revision.change_summary || "No description"}</p>
        </div>

        <div class="flex items-center justify-end gap-3">
          <button
            type="button"
            phx-click={@on_close}
            class="px-4 py-2 bg-white/[0.05] hover:bg-white/[0.1] text-text-secondary rounded-md text-sm font-medium transition-colors"
          >
            Cancel
          </button>
          <button
            type="button"
            phx-click="confirm_rollback"
            phx-value-revision_id={@revision.id}
            phx-target={@myself}
            class="px-4 py-2 bg-red-600 hover:bg-red-700 text-white rounded-md text-sm font-medium transition-colors"
          >
            Rollback
          </button>
        </div>
      </div>
    </.modal>
    """
  end

  def diff_content(assigns) do
    ~H"""
    <div class="space-y-4">
      <.diff_header diff={@diff} />
      <.diff_lines diff={@diff.diff} />
    </div>
    """
  end

  def diff_header(assigns) do
    ~H"""
    <div class="flex items-center justify-between pb-4 border-b border-border">
      <div class="flex items-center gap-4">
        <div class="text-sm">
          <span class="text-text-tertiary">From: </span>
          <span class="text-text-secondary ml-2">Revision {@diff.other.revision_number}</span>
        </div>
        <div class="text-sm">
          <span class="text-text-tertiary">To: </span>
          <span class="text-text-secondary ml-2">Revision {@diff.current.revision_number}</span>
        </div>
      </div>
    </div>
    """
  end

  def diff_lines(assigns) do
    ~H"""
    <div class="bg-white/[0.02] rounded-md border border-border overflow-hidden max-h-96 overflow-y-auto font-mono text-xs">
      <div
        :for={line <- @diff}
        id={"diff-line-#{line.type}"}
        class={[
          "flex",
          case line.type do
            :same -> "bg-transparent"
            :addition -> "bg-green-500/10"
            :deletion -> "bg-red-500/10"
            _ -> "bg-transparent"
          end
        ]}
      >
        <div
          :if={line.type != :same}
          class={[
            "w-8 flex-shrink-0 text-center",
            case line.type do
              :addition -> "text-green-500"
              :deletion -> "text-red-500"
              _ -> "text-text-quaternary"
            end
          ]}
        >
          {case line.type do
            :addition -> "+"
            :deletion -> "-"
            _ -> " "
          end}
        </div>
        <div class={["flex-1 whitespace-pre-wrap break-words px-2 py-0.5", line_class(line.type)]}>
          {line.line}
        </div>
      </div>
    </div>
    """
  end

  defp line_class(type) do
    case type do
      :addition -> "text-green-400"
      :deletion -> "text-red-400"
      :same -> "text-text-tertiary"
      _ -> "text-text-secondary"
    end
  end

  defp is_current_revision?(revision, current_id) do
    revision.id == current_id
  end

  defp format_timestamp(datetime) do
    datetime
    |> DateTime.shift_zone!("UTC", "Etc/UTC")
    |> Calendar.strftime("%b %d, %Y at %H:%M UTC")
  end
end
