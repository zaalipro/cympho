defmodule CymphoWeb.IssueLive.Show.ProgressPanel do
  use CymphoWeb, :html

  attr :progress, :map, default: nil

  def run_progress(assigns) do
    assigns =
      assign(
        assigns,
        :presentation,
        CymphoWeb.IssueLive.Show.RunProgress.presentation(assigns.progress)
      )

    ~H"""
    <section
      id="issue-run-progress"
      aria-label="Run progress"
      class="mx-4 my-3 border-l-2 border-brand/40 px-3 py-2 text-sm lg:mx-6"
    >
      <div class="flex flex-wrap items-center gap-x-3 gap-y-1">
        <h2 class="font-510 text-ink">{@presentation.label}</h2>
        <span class="text-ink-tertiary">{@presentation.detail}</span>
        <span :if={@presentation.elapsed != nil} class="text-xs text-ink-tertiary">
          Elapsed {@presentation.elapsed}s
        </span>
      </div>
      <p :if={@progress && @progress.sample} class="mt-1 text-xs text-ink-tertiary">
        {@progress.sample.bytes} bytes · {@progress.sample.chunks} chunks
      </p>
    </section>
    """
  end
end
